# ClamTk, copyright (C) 2004-2014 Dave M
#
# This file is part of ClamTk (http://code.google.com/p/clamtk/).
#
# ClamTk is free software; you can redistribute it and/or modify it
# under the terms of either:
#
# a) the GNU General Public License as published by the Free Software
# Foundation; either version 1, or (at your option) any later version, or
#
# b) the "Artistic License".
package ClamTk::Scan;

use Glib 'TRUE', 'FALSE';

# use strict;
# use warnings;
$| = 1;

use constant HATE_GNOME_SHELL    => -6;
use constant DESTROY_GNOME_SHELL => -11;

use POSIX 'locale_h',          'strftime';
use File::Basename 'basename', 'dirname';
use Locale::gettext;
use Encode 'decode';

binmode( STDIN,  ':utf8' );
binmode( STDOUT, ':utf8' );

my $SCAN;     # File handle for scanning
my $found;    # Holds information of bad stuff found

my $found_count = 0;    # Scalar number of bad stuff found
my $num_scanned = 0;    # Overall number of files scanned
my %dirs_scanned;       # Directories scanned
my $scan_pid;           # PID of scanner, for killing/cancelling scan

my $stopped = 1;            # Whether scanner is stopped (1) or running (0)
my $directive;              # Options sent to scanner
my $topbar;                 # Gtk2::InfoBar on top
my $bottombar;              # Gtk2::InfoBar on bottom
my $pb;                     # Gtk2::ProgressBar
my $spinner;                # Gtk2::Spinner
my $files_scanned_label;    # Gtk2::Label
my $threats_label;          # Gtk2::Label
my $dontshow;               # whether or not to show the preferences button

my $window;

sub filter {
    my ( $pkg_name, $scanthis, $dontshow1 ) = @_;
    $dontshow = $dontshow1;

    # We're gonna need these:
    my $paths = ClamTk::App->get_path( 'all' );
    my %prefs = ClamTk::Prefs->get_all_prefs();

    # Don't bother doing anything if clamscan can't be found
    if ( !-e $paths->{ clampath } ) {
        warn "Cannot scan without clamscan!\n";
        return;
    }

    # Begin popup 'scanning' crap.
    # We would normally use a statusicon, but GNOME
    # does not support it??
    $window = Gtk2::Window->new;
    $window->set_deletable( FALSE );
    $window->signal_connect(
        'delete-event' => sub {
            if ( !$stopped ) {
                return TRUE;
            }
        }
    );
    $window->set_title( _( 'Virus Scanner' ) );
    $window->set_border_width( 10 );
    $window->set_default_size( 300, 80 );

    my $images_dir = ClamTk::App->get_path( 'images' );
    if ( -e "$images_dir/clamtk.png" ) {
        my $pixbuf
            = Gtk2::Gdk::Pixbuf->new_from_file( "$images_dir/clamtk.png" );
        my $transparent = $pixbuf->add_alpha( TRUE, 0xff, 0xff, 0xff );
        $window->set_icon( $transparent );
    }

    my $eb = Gtk2::EventBox->new;
    $window->add( $eb );
    my $white = Gtk2::Gdk::Color->new( 0xFFFF, 0xFFFF, 0xFFFF );
    $eb->modify_bg( 'normal', $white );

    my $box = Gtk2::VBox->new( FALSE, 5 );
    $eb->add( $box );

    my $hbox = Gtk2::HBox->new( FALSE, 0 );
    $box->add( $hbox );

    $topbar = Gtk2::InfoBar->new;
    $hbox->pack_start( $topbar, TRUE, TRUE, 5 );

    Gtk2->main_iteration while ( Gtk2->events_pending );
    $topbar->set_message_type( 'other' );
    set_infobar_text( $topbar, _( 'Preparing...' ) );
    Gtk2->main_iteration while ( Gtk2->events_pending );

    $spinner = Gtk2::Spinner->new;
    $hbox->pack_start( $spinner, FALSE, FALSE, 5 );

    $pb = Gtk2::ProgressBar->new;
    $box->pack_start( $pb, FALSE, FALSE, 5 );
    $pb->set_fraction( .25 );

    $files_scanned_label
        = Gtk2::Label->new( sprintf _( "Files scanned: %d" ), $num_scanned );
    $files_scanned_label->set_alignment( 0.0, 0.5 );

    $threats_label
        = Gtk2::Label->new( sprintf _( "Possible threats: %d" ),
        $found_count );
    $threats_label->set_alignment( 0.0, 0.5 );

    my $text_box = Gtk2::VBox->new( FALSE, 5 );
    $text_box->add( $files_scanned_label );
    $text_box->add( $threats_label );

    $bottombar = Gtk2::InfoBar->new;
    $box->pack_start( $bottombar, FALSE, FALSE, 5 );
    $bottombar->can_focus( FALSE );

    $bottombar->set_message_type( 'info' );
    $bottombar->add_button( 'gtk-cancel', HATE_GNOME_SHELL );
    if ( !$dontshow ) {
        $bottombar->add_button( 'gtk-preferences', DESTROY_GNOME_SHELL );
    }
    $bottombar->signal_connect(
        response => sub {
            my ( $bar, $button ) = @_;
            if ( $button eq 'cancel' ) {
                cancel_scan();
            } elsif ( $button eq 'help' ) {
                system( 'clamtk &' );
                return FALSE;
            }
        }
    );
    $bottombar->get_content_area->add( $text_box );

    $window->show_all;
    $window->set_gravity( 'south-east' );
    $window->queue_draw;
    $window->set_position( 'mouse' );
    Gtk2->main_iteration while ( Gtk2->events_pending );

    # Try to avoid MS Windows file systems...
    $directive .= ' --cross-fs=no';

    # Try to avoid scanning emails...
    $directive .= ' --scan-mail=no';

    # By default, we ignore .gvfs directories.
    # Once we figure out KDE's process, we'll exclude that too.
    #<<<
    for my $m (
            'smb4k',
            "/run/user/$ENV{USER}/gvfs",
            "$ENV{HOME}/.gvfs" ) {
                $directive .= " --exclude-dir=$m";
    }
    #>>>

    # Now strip whitelisted directories
    for my $ignore (
        split(
            /;/,
            ClamTk::Prefs->get_preference( 'Whitelist' )
                . $paths->{ whitelist_dir }
        )
        )
    {
        $directive .= " --exclude-dir=" . quotemeta( $ignore );
    }

    # Remove mail directories for now -
    # until we can parse them... sigh.
    # Not all of these can be appended to $HOME for a more
    # specific path - kmail (e.g.) is somewhere
    # under $HOME/.kde/blah/foo/...
    my @maildirs = qw(
        .thunderbird	.mozilla-thunderbird
        Mail	kmail   evolution
    );
    for my $mailbox ( @maildirs ) {
        $directive .= " --exclude-dir=$mailbox";
    }

    # remove the hidden files if chosen:
    if ( !$prefs{ ScanHidden } ) {
        $directive .= ' --exclude="\/\."';
    }

    # symlinks:
    # The symlink stuff from clamscan requires >= 0.97.
    my ( $version ) = ClamTk::App->get_AV_version();
    # Ensure it's just digits and dots:
    $version =~ s/[^0-9\.]//g;
    if (   ( $version cmp '0.97' ) == 0
        || ( $version cmp '0.97' ) == 1 )
    {
        $directive .= ' --follow-dir-symlinks=1';
        $directive .= ' --follow-file-symlinks=1';
    }

    # we'll count this as ! $stopped
    #$stopped = 0;

    # reset %$found
    $found = {};

    # These lines are for 'thorough'. :)
    # If it's selected, we add detection for both
    # potentially unwanted applications and broken executables.
    if ( $prefs{ Thorough } ) {
        $directive .= ' --detect-pua --detect-broken';
    } else {
        $directive =~ s/\s--detect-pua --detect-broken//;
    }

    # only a single file

    # By default, 20Mb is the largest we go -
    # unless the preference is to ignore size.
    if ( !$prefs{ SizeLimit } ) {
        $directive .= ' --max-filesize=20M';
    }

    if ( !$prefs{ Recursive } ) {
        $directive .= ' --max-dir-recursion=1';
    } else {
        $directive .= ' --recursive=yes';
    }

    scan( $scanthis, $directive );

    clean_up();
}

sub scan {
    my ( $path_to_scan, $directive ) = @_;
    $pb->set_fraction( .50 );
    $spinner->start;
    my $quoted = quotemeta( $path_to_scan );

    # Leave if we have no real path
    if ( !$path_to_scan ) {
        warn "No path to scan!\n";
        return;
    }

    my $paths   = ClamTk::App->get_path( 'all' );
    my $command = $paths->{ clamscan };

    # Use the user's sig db if it's selected
    if ( ClamTk::Prefs->get_preference( 'Update' ) eq 'single' ) {
        $command .= " --database=$paths->{db}";
    }

    # Implicit fork; gives us the PID of clamscan so we can
    # kill it if the user hits the Stop button
    #<<<
    Gtk2->main_iteration while ( Gtk2->events_pending );
    $scan_pid
        = open( $SCAN, '-|', "$command $directive $quoted 2>&1" );
    defined( $scan_pid ) or die "couldn't fork: $!\n";
    $window->queue_draw;
    Gtk2->main_iteration while ( Gtk2->events_pending );
    #>>>
    # binmode( $SCAN, ':utf8:bytes' );

    Gtk2->main_iteration while ( Gtk2->events_pending );
    while ( <$SCAN> ) {
        Gtk2->main_iteration while ( Gtk2->events_pending );
        $window->queue_draw;

        next if ( /^LibClamAV/ );
        next if ( /^\s*$/ );

        my ( $file, $status );
        if ( /(.*?): ([^:]+) FOUND/ ) {
            $file   = $1;
            $status = $2;
        } elsif ( /(.*?): (OK)$/ ) {
            $file   = $1;
            $status = $2;
        }    #else {
             #warn "something else: file = <$file>, stat = <$status>\n";
             #}

        # Ensure the file is still there (things get moved)
        # and that it got scanned
        next unless ( $file && -e $file && $status );
        next if ( $status =~ /module failure/ );

        chomp( $file )   if ( defined $file );
        chomp( $status ) if ( defined $status );

        my $dirname = decode( 'UTF-8', dirname( $file ) );
        #<<<
        # Display stuff in popup infobar
        set_infobar_text( $topbar,
            sprintf( _( 'Scanning %s...' ), $dirname )
        );
        #>>>
        $topbar->show_all;
        Gtk2->main_iteration while ( Gtk2->events_pending );
        $window->queue_draw;

        # Lots of temporary things under /tmp/clamav;
        # we'll just ignore them.
        $dirs_scanned{ $dirname } = 1
            unless ( dirname( $file ) =~ /\/tmp\/clamav/
            || dirname( $file ) eq '.' );

        # Do not show files in archives - we just want the end-result.
        # It still scans and we still show the result.
        next if ( $file =~ /\/tmp\/clamav/ );

        # $status is the "virus" name.
        $status =~ s/\s+FOUND$//;

        # These aren't necessarily clean (despite the variable's name)
        # - we just don't want them counted as viruses
        my $clean_words = join( '|',
            'OK',
            'Zip module failure',
            "RAR module failure",
            'Encrypted.RAR',
            'Encrypted.Zip',
            'Empty file',
            'Excluded',
            'Input/Output error',
            'Files number limit exceeded',
            'handler error',
            'Broken.Executable',
            'Oversized.Zip',
            'Symbolic link' );

        if ( $status !~ /$clean_words/ ) {    # a virus
            $found->{ $found_count }->{ name }   = $file;
            $found->{ $found_count }->{ status } = $status;
            $found->{ $found_count }->{ action } = _( 'None' );
            $found_count++;
            $threats_label->set_text( sprintf _( "Possible threats: %d" ),
                $found_count );
        }

        $num_scanned++;
        $files_scanned_label->set_text( sprintf _( "Files scanned: %d" ),
            $num_scanned );

        Gtk2->main_iteration while ( Gtk2->events_pending );
    }

    Gtk2->main_iteration while ( Gtk2->events_pending );

    # Done scanning - close filehandle and return to
    # filter() and then to clean-up
    close( $SCAN );    # or warn "Unable to close scanner! $!\n";
}

sub cancel_scan {
    kill 15, $scan_pid + 1;
    waitpid( $scan_pid + 1, 0 ) if ( $scan_pid + 1 );
    kill 15, $scan_pid if ( $scan_pid );
    waitpid( $scan_pid, 0 ) if ( $scan_pid );

    close( $SCAN );
    $stopped = 1;
}

sub clean_up {
    set_infobar_text( $topbar, _( 'Cleaning up...' ) );
    $pb->set_fraction( .75 );
    $spinner->stop;
    $spinner->hide;
    destroy_buttons();
    add_closing_buttons();

    my $message = '';
    if ( !$found_count ) {
        $message = _( 'Scanning complete' );
    } else {
        $message = _( 'Possible threats found' );
    }
    set_infobar_text( $topbar, _( $message ) );

    # Save scan information
    logit();

    $pb->set_fraction( 1.00 );

    if ( $found_count ) {
        ClamTk::Results->show_window( $found );
    } else {
        bad_popup();
    }

    # reset things
    $num_scanned  = 0;
    $found_count  = 0;
    %dirs_scanned = ();
    $stopped      = 1;
    $directive    = '';
}

sub bad_popup {
    my $dialog = Gtk2::MessageDialog->new(
        $window, [ qw| modal destroy-with-parent | ],
        'info', 'close', _( 'No threats found' ),
    );
    $dialog->run;
    $dialog->destroy;
}

sub logit {
    my $db_total = ClamTk::App->get_sigtool_info( 'count' );
    my $REPORT;    # filehandle for histories log

    #<<<
    my ( $mon, $day, $year )
        = split / /, strftime( '%b %d %Y', localtime );

    # Save date of scan
    if ( $found_count > 0 ) {
        ClamTk::Prefs->set_preference(
                'LastInfection', "$day $mon $year"
        );
    }
    #>>>

    my %prefs = ClamTk::Prefs->get_all_prefs();
    my $paths = ClamTk::App->get_path( 'history' );

    my $virus_log
        = $paths . "/" . decode( 'utf8', "$mon-$day-$year" ) . '.log';

    #<<<
    # sort the directories scanned for display
    my @sorted = sort { $a cmp $b } keys %dirs_scanned;
    if ( open $REPORT, '>>:encoding(UTF-8)', $virus_log ) {
        print $REPORT "\nClamTk, v",
            ClamTk::App->get_TK_version(), "\n",
            scalar localtime,
            "\n";
        print $REPORT sprintf _(
                "ClamAV Signatures: %d\n" ),
                $db_total;
        print $REPORT _( "Directories Scanned:\n" );
        for my $list ( @sorted ) {
            print $REPORT "$list\n";
        }
        printf $REPORT _(
            "\nFound %d possible %s (%d %s scanned).\n\n" ),
            $found_count,
            $found_count == 1 ? _( 'threat' ) : _( 'threats' ),
            $num_scanned,
            $num_scanned == 1 ? _( 'file' ) : _( 'files' );
    } else {
            warn "Could not write to logfile. Check permissions.\n";
    }
    #>>>

    # Set the minimum sizes for the two columns,
    # the filename and its status - if we're saving a log (which we
    # do, by default)
    my $lsize = 20;
    my $rsize = 20;
    if ( $found_count == 0 ) {
        print $REPORT _( "No threats found.\n" );
    } else {
        # Now get the longest lengths of the column contents.
        for my $length ( sort keys %$found ) {
            $lsize
                = ( length( $found->{ $length }->{ name } ) > $lsize )
                ? length( $found->{ $length }->{ name } )
                : $lsize;
            $rsize
                = ( length( $found->{ $length }->{ status } ) > $rsize )
                ? length( $found->{ $length }->{ status } )
                : $rsize;
        }
        # Set a buffer which is probably unnecessary.
        $lsize += 5;
        $rsize += 5;
        # Print to the log:
        for my $num ( sort keys %$found ) {
            printf $REPORT "%-${lsize}s %-${rsize}s\n",
                decode( 'utf8', $found->{ $num }->{ name } ),
                $found->{ $num }->{ status };
        }
    }

    print $REPORT '-' x ( $lsize + $rsize + 5 ), "\n";
    close( $REPORT );

    return;
}

sub set_infobar_text {
    my ( $bar, $text ) = @_;

    Gtk2->main_iteration while ( Gtk2->events_pending );
    for my $c ( $bar->get_content_area->get_children ) {
        if ( $c->isa( 'Gtk2::Label' ) ) {
            $c->set_text( $text );
            Gtk2->main_iteration while ( Gtk2->events_pending );
            return;
        }
    }

    #<<<
    my $label = Gtk2::Label->new;
    $label->set_text( _( $text ) );
    $label->set_alignment( 0.0, 0.5 );
    $label->set_ellipsize( 'middle' );
    $bar->get_content_area->add(
            #Gtk2::Label->new( _( $text ) )
            $label
    );
    #>>>
    $window->queue_draw;
    Gtk2->main_iteration while ( Gtk2->events_pending );

}

sub add_default_buttons {
    # We're going to show the following:
    # cancel-button: obviously cancels the scan
    # prefs-button: allows popup 'clamtk' with no args, for settings.
    # We don't even need translations for this.
    $bottombar->add_button( 'gtk-cancel',      HATE_GNOME_SHELL, );
    $bottombar->add_button( 'gtk-preferences', DESTROY_GNOME_SHELL, );

    $bottombar->signal_connect(
        response => sub {
            my ( $bar, $response ) = @_;
            if ( $response eq 'cancel' ) {
                cancel_scan();
                return TRUE;
            } elsif ( $response eq 'help' ) {
                system( 'clamtk &' );
                return FALSE;
            }
        }
    );
}

sub add_closing_buttons {
    $bottombar->add_button( 'gtk-close', -7 );
    if ( !$dontshow ) {
        $bottombar->add_button( 'gtk-preferences', DESTROY_GNOME_SHELL, );
    }

    $bottombar->signal_connect(
        response => sub {
            my ( $bar, $response ) = @_;
            if ( $response eq 'close' ) {
                $window->destroy;
            } elsif ( $response eq 'help' ) {
                system( 'clamtk &' );
                return FALSE;
            }
        }
    );
    $bottombar->show_all;
}

sub destroy_buttons {
    for my $c ( $bottombar->get_action_area->get_children ) {
        if ( $c->isa( 'Gtk2::Button' ) ) {
            $c->destroy;
        }
    }
    return TRUE;
}

1;
