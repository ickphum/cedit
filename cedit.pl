#!/usr/bin/perl -w -- 
#$Id: iso.pl 151 2012-11-11 10:05:50Z ikm $

use Wx qw[:everything];

use strict;
use warnings;

use Log::Log4perl qw(get_logger);
use Getopt::Long;
use Data::Dumper qw(Dumper);
use FindBin qw($Bin);
use List::Util qw(max min);
use English qw(-no_match_vars);

# main variables {{{1

my $log;

# CeditApp {{{1

package CeditApp;

use strict;
use warnings;

use Wx qw[:everything wxTheClipboard];
use base qw(Wx::App Class::Accessor::Fast);
use Data::Dumper;
use File::Basename;
use File::Slurp qw(read_file write_file);
use Wx::XRC;
use Wx::DND;
use Digest::SHA qw(sha1_hex);
use Crypt::CBC;
use YAML::XS qw(Dump Load);
use English qw(-no_match_vars);

__PACKAGE__->mk_accessors( qw(frame xrc filename key saved_checksum control current_dir cipher 
    default_style dialogue_style dialogue_transitions) 
    );

my $current_line_count;

sub new { # {{{2
    my( $class, $option ) = @_;
    my $self = $class->SUPER::new();

    die "No main.xrc" unless -f 'main.xrc';

    $self->xrc( Wx::XmlResource->new() );
    $self->xrc->InitAllHandlers;
#    my $custom_xrc_handler = CeditXRCHandler->new ;
#    $custom_xrc_handler->AddStyle('wxWANTS_CHARS', wxWANTS_CHARS);
#    $self->xrc->AddHandler($custom_xrc_handler);

    $self->xrc->Load('main.xrc');

    $self->frame( $self->xrc->LoadFrame(undef, 'main'));
#    my $icon_image = Wx::Image->new('image/cedit.png', wxBITMAP_TYPE_ANY);
#    $self->frame->SetIcon(Wx::Icon->new($icon_image));

    Wx::Event::EVT_MENU($self->frame, wxID_NEW, \&new_file);
    Wx::Event::EVT_MENU($self->frame, wxID_OPEN, \&open_file);
    Wx::Event::EVT_MENU($self->frame, wxID_SAVE, \&save_file);
    Wx::Event::EVT_MENU($self->frame, wxID_ZOOM_IN, sub { $self->change_font_size(2); });
    Wx::Event::EVT_MENU($self->frame, wxID_ZOOM_OUT, sub { $self->change_font_size(-2); });
    Wx::Event::EVT_MENU($self->frame, wxID_HELP, sub { $self->toggle_dialogue_style; });
#    Wx::Event::EVT_MENU($self->frame, wxID_DOWN, sub { $self->shift_dialogue_styles(1); });
#    Wx::Event::EVT_MENU($self->frame, wxID_UP, sub { $self->shift_dialogue_styles(-1); });
    Wx::Event::EVT_MENU($self->frame, wxID_SAVEAS, \&copy_to_html);
    Wx::Event::EVT_MENU($self->frame, wxID_REFRESH, sub { $self->refresh_dialogue_styles; }); 
#        sub {
#
#            # ShowPosition puts the specified position at the bottom of the window, so find out
#            # what position is there now.
#            my $text_txt = wxTheApp->control->{text_txt};
#            my (undef, $height) = $text_txt->GetSizeWH;
#            my ($status, $column, $row) = $text_txt->HitTest([0,$height - 10]);
#            my $position = $text_txt->XYToPosition($column, $row);
#
#            # fake a font size change to refresh the styles
#            $self->change_font_size(1);
#            $self->change_font_size(-1);
#
#            # show previous position
#            $text_txt->ShowPosition($position);
#
#            return;
#        });
    Wx::Event::EVT_MENU($self->frame, wxID_FIND, 
        sub {

            my $text_txt = wxTheApp->control->{text_txt};
            my $find_str = wxTheApp->frame->GetToolBar->FindControl(wxID_FORWARD)->GetValue;

            wxTheApp->search_text_forward($find_str);

            return;
        });
    Wx::Event::EVT_MENU($self->frame, wxID_REPLACE, 
        sub {

            my $text_txt = wxTheApp->control->{text_txt};
            my $replace_str = wxTheApp->frame->GetToolBar->FindControl(wxID_MORE)->GetValue;
            my ($start, $end) = $text_txt->GetSelection;
            if ($end > $start) {
                $text_txt->Replace($start, $end, $replace_str);

                my $find_str = wxTheApp->frame->GetToolBar->FindControl(wxID_FORWARD)->GetValue;
                wxTheApp->search_text_forward($find_str);
            }

            return;
        });

    $self->frame->SetAcceleratorTable( Wx::AcceleratorTable->new (
        [ wxACCEL_CTRL, ord('S'), wxID_SAVE ],
        [ wxACCEL_CTRL, ord('D'), wxID_HELP ],
        [ wxACCEL_CTRL, ord('F'), wxID_FIND ],
        [ wxACCEL_CTRL, ord('R'), wxID_REPLACE ],
    ));

    Wx::Event::EVT_CLOSE($self->frame, sub {
        my ($frame, $event) = @_;

        if ($self->check_for_changes) {
            $frame->Destroy;
        }
        else {
            $event->Veto;
        }
    });

    my ($width, $height, $left, $top);

    if (my $geometry = $option->{geometry}) {
        $log->logdie("bad geometry setting") unless $geometry =~ /(\d+)x(\d+)(?::(\d+),(\d+))?/;
        ($width, $height, $left, $top) = ($1,$2,$3,$4);
        $left ||= 0;
        $top ||= 0;
    }
    else {
        ($width, $height, $left, $top) = (550,400,400,400);
    }
    $log->debug("screen geom $width x $height @ $left, $top");
    $self->frame->SetSize($left, $top, $width, $height);

    $self->control({});
    for my $child ( $self->frame->GetChildren ) {
        $log->debug("child $child " . $child->GetName);
        $self->control->{ $child->GetName } = $child;
    }

    # put the text controls in the toolbar in control as well
#    my $toolbar = $self->frame->GetToolBar;
#    $self->control->{find_txt} = $toolbar->FindById(wxID_FIND)->GetControl
#        or die "can't find find_txt";

    my $text_txt = $self->control->{text_txt};

    $self->SetTopWindow($self->frame);
    $self->frame->Show(1);

    $self->current_dir($option->{bin_dir});

    # initialise a blank checksum so we know how long a checksum is
    $self->saved_checksum( sha1_hex('') );

    my $dialogue_style = Wx::TextAttr->new(wxBLACK, Wx::Colour->new('#dddddd'));
#    $dialogue_style->SetLeftIndent(100);
    $self->dialogue_style($dialogue_style);
    my $default_style = Wx::TextAttr->new($text_txt->GetForegroundColour, $text_txt->GetBackgroundColour);
#    $default_style->SetLeftIndent(0);
    $self->default_style($default_style);
#    $self->dialogue_line({});
#    $self->dialogue_transitions([]);

    if ($option->{file}) {
        open_file($self->frame, undef, $option);
    }
    else {
        $text_txt->SetValue("Here's some sample text.\nNew line.\n\nNew paragraph\n\nA plain a b c 1 2 3 scalar is unquoted.\n\nAll plain scalars are automatic candidates for implicit tagging.\n\nThis means that their tag may be determined automatically by examination.\n\nThe typical uses for this are plain alpha strings, integers, real numbers, dates, times and currency.");
#        $text_txt->SetStyle(50, 100, $dialogue_style);
    }

#    my $stylesheet = Wx::RichTextStyleSheet->new;
#    my $dialog_style = Wx::RichTextParagraphStyleDefinition->new('dialog');
#    my $dialog_attr = Wx::RichTextAttr->new;
#    $dialog_attr->SetLeftIndent(100,200);
#    $dialog_style->SetStyle($dialog_attr);
#    $stylesheet->AddParagraphStyle($dialog_style);
#    $text_txt->SetStyleSheet($stylesheet);

    $current_line_count = $text_txt->GetNumberOfLines;
    Wx::Event::EVT_CHAR($text_txt, sub {
        my ($frame, $event) = @_;

        my $text_txt = $event->GetEventObject;

        my ($keycode, $shift_down, $ctrl_down) = ($event->GetKeyCode, $event->ShiftDown, $event->ControlDown);
        my ($selection_from, $selection_to) = $text_txt->GetSelection;
        my $selected_text = $text_txt->GetStringSelection;
        my $selection_length = $selection_to - $selection_from;
        my $current_location = $text_txt->GetInsertionPoint;
        my $end_of_text = $text_txt->GetLastPosition;

        # on Windows, handle the 'feature' by which double-clicking on a word selects the
        # word and the following space, but if a printable character is entered, the space is not removed
        # with the rest of the selection. 
        if ($selection_length > 1 && $keycode >= 32 && $keycode <= 126 && $OSNAME =~ /Win32/ && $selected_text =~ /\s\z/) {
#            $log->info("fix word selection");
            $selection_length--;
        }

        # only check on the clipboard if we need to, ie we're pasting
        my $clipboard_length = 0;
        if ($keycode == 22) {

            # copied from wxperl_demo.pl
            wxTheClipboard->Open;
            my $unicodetext_wxwidgets_id = 13;
            my $unicodetextformat = ( defined(&Wx::wxDF_UNICODETEXT) ) 
                ? wxDF_UNICODETEXT() 
                : Wx::DataFormat->newNative( $unicodetext_wxwidgets_id );
            if( wxTheClipboard->IsSupported( wxDF_TEXT ) || wxTheClipboard->IsSupported( $unicodetextformat ) ) {
                my $data = Wx::TextDataObject->new;
                my $ok = wxTheClipboard->GetData( $data );
                if( $ok ) {
                    $clipboard_length = length $data->GetText;
                }
            }
            wxTheClipboard->Close;
        }

        my $input_length = ($keycode >= 32 && $keycode <= 126) || $keycode == 13
            ? 1                                     # printable chars
            : $keycode == 8                        # backspace
                ? $selection_length || $current_location == 0
                    ? 0                             # with selection or at start of buffer, 0 chars inserted
                    : -1                            # otherwise, one char removed
                : $keycode == 127                  # delete
                    ? $selection_length || $current_location == $end_of_text
                        ? 0                         # with selection or at end of buffer, 0 chars inserted
                        : -1                        # otherwise, one char removed
                    : $keycode == 24
                        ? 0                         # cut always adds 0 chars, may remove selection
                        : $keycode == 22
                            ? $clipboard_length     # paste
                            : undef;                # all other keys don't change the buffer

        $event->Skip;

        return unless defined $input_length;

        # change in transitions from this point on is input length - selection length
        return unless my $transition_change = $input_length - $selection_length;

#        $log->info("transition_change $transition_change, keycode $keycode at $current_location, end = $end_of_text, selection '$selected_text' length = $selection_length, clipboard = $clipboard_length; input length " 
#            . (defined $input_length ? $input_length : 'undef'));

        my $dialogue_transitions = $self->dialogue_transitions;
        for my $i (0 .. $#{ $dialogue_transitions }) {

            # we want to match the end where we're on it (so it gets pushed if we type at the end of dialog)
            # but not the start (so it stays still if we type at the start of dialog)
            if (($i % 2 == 0 && $dialogue_transitions->[$i] > $current_location)
                || ($i % 2 && $dialogue_transitions->[$i] >= $current_location))
            {
                for my $j ($i .. $#{ $dialogue_transitions }) {
                    $dialogue_transitions->[$j] += $transition_change;
                }
                last;
            }
        }

#        $log->info("dialogue_transitions now " . Dumper($dialogue_transitions));

        return;
    });

    return $self;
}

################################################################################
# Just clear the text control and the filename and key attributes
sub new_file { #{{{2
    my ($frame, $event) = @_;

    my $app = wxTheApp;
    return unless $app->check_for_changes;

    $app->control->{text_txt}->Clear;
    $app->saved_checksum( sha1_hex('') );
    $app->{filename} = undef;
    $app->{key} = undef;

    return;
}

################################################################################
sub save_file { #{{{2
    my ($frame, $event) = @_;

    my $app = wxTheApp;

    unless ($app->filename) {

        my $file_dialog = Wx::FileDialog->new($frame, "Choose a filename", $app->current_dir, '', 'Cedit files|*.ced|All files|*', wxFD_SAVE);
        return unless $file_dialog->ShowModal == wxID_OK;

        my $filename = $file_dialog->GetPath;
        if (-f $filename) {
            return unless wxYES == Wx::MessageBox("File '$filename' exists; ok to overwrite?", "Confirm Overwrite", wxYES_NO, $frame);
        }
        $app->current_dir($file_dialog->GetDirectory);
        $app->filename( $filename );

        my $key;
        while (1) {
            return unless $key = Wx::GetPasswordFromUser("Choose key", "Key Entry", "", $frame);
            return unless my $confirm_key = Wx::GetPasswordFromUser("Confirm key", "Key Entry", "", $frame);

            last if $key eq $confirm_key;

            Wx::MessageBox("The keys do not match.", "No Match", wxOK, $frame);
        }

        $app->key( $key );
        $app->cipher( Crypt::CBC->new( -key => $key, -cipher => 'Blowfish') );
    }

    my ($filename, $key) = ($app->filename, $app->key);

    my $text_txt = $app->control->{text_txt};
    my $edit_text = $text_txt->GetValue;
    my $checksum = sha1_hex($edit_text);
    $app->saved_checksum($checksum);

    my ($width, $height) = $frame->GetSizeWH;
    my ($left, $top) = $frame->GetPositionXY;

    my $yaml = Dump({
#        dialogue_line => $app->dialogue_line,
        dialogue_transitions => $app->dialogue_transitions,
        font_size => $text_txt->GetFont->GetPointSize,
        left => $left,
        top => $top,
        width => $width,
        height => $height,
    });

#    my @yaml_chars = unpack('C*', $yaml);
#    $log->info("yaml: $yaml");
#    $log->info("yaml_chars: @yaml_chars");
#
#    $yaml =~ s/\r\n/\n/g;
#
#    @yaml_chars = unpack('C*', $yaml);
#    $log->info("yaml: $yaml");
#    $log->info("yaml_chars: @yaml_chars");

    # save the checksum so we can identify wrong keys
    my $file_text = $checksum . pack('S', length $yaml) . $yaml . $app->cipher->encrypt($edit_text);

    write_file($filename, { binmode => ':raw' }, \$file_text);

    $log->info("save to $filename");

    return;
}

################################################################################
sub open_file { #{{{2
    my ($frame, $event, $option) = @_;

    my $app = wxTheApp;
    return unless $app->check_for_changes;

    my $filename = $option->{file};

    unless ($filename) {

        my $file_dialog = Wx::FileDialog->new($frame, "Choose a file to open", $app->current_dir, '', 'Cedit files|*.ced|All files|*', wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        return unless $file_dialog->ShowModal == wxID_OK;
        $filename = $file_dialog->GetPath;
        $app->current_dir($file_dialog->GetDirectory);
    }

    my $key = $option->{key};
    unless ($key) { 
        return unless $key = Wx::GetPasswordFromUser("Enter key", "Key Entry", "", $frame);
    }
    $app->cipher( Crypt::CBC->new( -key => $key, -cipher => 'Blowfish') );

    $log->debug("open from $filename");
    my $file_text = read_file($filename, binmode => ':raw');

    # the file text contains the checksum of the plaintext, so we can warn about incorrect keys.
    # Assume that all checksums will be the same length (until we do something silly like change the checksum method).
    my $checksum_length = length $app->saved_checksum;

    my $file_checksum = substr($file_text, 0, $checksum_length, '');

    # remove and unpack the yaml chunk
    my $yaml_length = unpack('S', substr($file_text, 0, 2, ''));
    my $yaml = substr($file_text, 0, $yaml_length, '');
#    $log->info("yaml length $yaml_length : $yaml");

    my $edit_text = $app->cipher->decrypt($file_text);
    my $edit_checksum = sha1_hex($edit_text);

    if ($file_checksum ne $edit_checksum) {
        my $message = <<"EOT";
The checksum calculated from the file doesn't match
the one stored in the file; the key may have been incorrect.

Do you wish to display the possibly garbled file? There's almost no chance of this being useful.
EOT
        return unless wxYES == Wx::MessageBox($message, "Bad Checksum", wxYES_NO, $frame);
    }

    my $property = Load($yaml) ;

    $app->control->{text_txt}->SetValue( $edit_text );

    # apply the properties
#    $app->dialogue_line( $property->{dialogue_line} );
    $app->dialogue_transitions( $property->{dialogue_transitions} );
    $app->change_font_size(0, $property->{font_size});
    $frame->SetSize($property->{width}, $property->{height});
    $frame->Move([ $property->{left}, $property->{top} ]);

#    $app->refresh_dialogue_styles;

    # set once open is successful
    $app->saved_checksum($edit_checksum);
    $app->filename($filename);
    $app->key($key);

    return;
}

################################################################################
sub change_font_size { #{{{2
    my ($self, $increment, $size) = @_;

    my $text_txt = $self->control->{text_txt};

    my $font = $text_txt->GetFont;
    $size ||= $font->GetPointSize + $increment;
    $font->SetPointSize($size);
    $text_txt->SetFont($font);

    $self->refresh_dialogue_styles;

    return;
}

################################################################################
sub toggle_dialogue_style { #{{{2
    my ($self, $line_nbr) = @_;

    my $text_txt = $self->control->{text_txt};

    my ($start, $end, $switch_on);

    my $cursor_pos = $text_txt->GetInsertionPoint;
    my $text = $text_txt->GetValue;
    my $bg_color = $text_txt->GetStyle($cursor_pos)->GetBackgroundColour;
    $switch_on = $bg_color->Red != 0xdd;

    $start = $cursor_pos;
    $end = $cursor_pos;
    my @chars = unpack('C*', $text);

    # go back to previous LF, but if we're on an empty line, just quit
    if ($chars[$start] == 10) {
        if ($start == 0 || $chars[$start-1] == 10) {
            return;
        }

        # we're starting at the end of a non-empty line; move start 1 char backward so we
        # don't immediately terminate
        $start--;
    }
    while ($start >= 0 && $chars[$start] != 10) {
        $start--;
    }
    $start++;

    # go forward to next LF
    while ($end <= $#chars && $chars[$end] != 10) {
        $end++;
    }

    my $style;
    my $dialogue_transitions = $self->dialogue_transitions;

    # find the highest transition less than or equal to the current position;
    # we need this whether we're setting or clearing.
    # Do this manually rather than via List::MoreUtils because we know the list is sorted
    # and can stop earlier.
    my $active_transition_index = -1;
    for my $i (0 .. $#{ $dialogue_transitions }) {

        # we match on the start but before the end, otherwise we match the end of the
        # currrent transition when we're at the end of a styled line.
        if (($i % 2 == 0 && $dialogue_transitions->[$i] <= $cursor_pos) 
            || ($i % 2 && $dialogue_transitions->[$i] < $cursor_pos))
        {
            $active_transition_index = $i;
        }
        else {
            last;
        }
    }

    if ($switch_on) {
        $style = $self->dialogue_style;
#        $self->dialogue_line->{ $line_nbr } = 1;

        # the last transition (if any) should be a switch off, hence an odd index
        if ($active_transition_index >= 0 && ($active_transition_index % 2 == 0)) {
            $log->info("switch on inside an existing transition: $cursor_pos, $active_transition_index, " . Dumper($dialogue_transitions));
            return;
        }

        # add after previous transition or at start if none
        $active_transition_index++;
        splice @{ $dialogue_transitions }, $active_transition_index, 0, $start, $end;
    }
    else {
        $style = $self->default_style;
#        delete $self->dialogue_line->{ $line_nbr };

        # the last transition should be a switch on, hence an even index
        if ($active_transition_index < 0 || $active_transition_index % 2) {
            $log->info("switch off outside an existing transition: $cursor_pos, $active_transition_index, " . Dumper($dialogue_transitions));
            return;
        }

        # remove this transition
        splice @{ $dialogue_transitions }, $active_transition_index, 2;

    }

#    $log->info("dialogue_transitions now " . Dumper($dialogue_transitions));
    $self->dialogue_transitions($dialogue_transitions);
    $text_txt->SetStyle($start, $end, $style);

    return;
}

################################################################################
#sub shift_dialogue_styles { #{{{2
#    my ($self, $increment) = @_;
#
#    my $text_txt = $self->control->{text_txt};
#
##    my $left_indent;
##    my $switches = 0;
##    for my $position (0 .. $text_txt->GetLastPosition) {
##        if (my $style = $text_txt->GetStyle($position)) {
##            # $log->info("found style at $position");
##            if (! defined $left_indent || $left_indent != $style->GetLeftIndent) {
##                $left_indent = $style->GetLeftIndent;
##                $switches++;
##            }
##        }
##    }
##
##    $log->info("found $switches switches");
##    return;
#
#    my $pos = $text_txt->GetInsertionPoint;
#    (undef, my $current_line) = $text_txt->PositionToXY($pos);
#    $log->debug("shift_dialogue_styles: current_line $current_line, increment $increment");
#
#    my @dialogue_lines = sort { $increment > 0 ? $b <=> $a : $a <=> $b } keys %{ $self->dialogue_line };
#
#    for my $line_nbr (@dialogue_lines) {
#        next unless $line_nbr >= $current_line;
#        $log->debug("shift dialogue style from $line_nbr to $line_nbr + $increment");
#        $self->toggle_dialogue_style($line_nbr);
#        $self->toggle_dialogue_style($line_nbr + $increment);
#    }
#
#    return;
#}

################################################################################
# Note that this won't take off any styles, so it only works after a load or a font
# size change.
sub refresh_dialogue_styles { #{{{2
    my ($self) = @_;

    my @caller = caller(1);
#    return;
#    $log->info("refresh_dialogue_styles $caller[1] $caller[3] $caller[2]");

    my $text_txt = $self->control->{text_txt};
    my $last_position = $text_txt->GetLastPosition;
    $text_txt->SetStyle(0, $last_position, $self->default_style);
    my $full_text = $text_txt->GetValue;

    my $transitions = $self->dialogue_transitions;
    my $count = $#{ $transitions } + 1;
    if ($count % 2) {
        $log->die("transitions has odd number of chars : " . Dumper($transitions));
    }
    my $i = 0;
    my @valid_transitions = ();
    while ($i < $count) {
        my $start = $transitions->[$i];
        my $end = $transitions->[$i + 1];
        $i += 2;
#        if ($i < 10) {
            my $start_text = substr $full_text, $start-2, 5;
            my $end_text = substr $full_text, $end-2, 5;
            my @start_chars = unpack('C*', $start_text);
            my @end_chars = unpack('C*', $end_text);
#            $log->info("offset $i, $start to $end, chars = @start_chars to @end_chars");
            if (@start_chars == 5 && @end_chars == 5) {
                if ($start_chars[1] != 10 || $end_chars[2] != 10) {
                    $log->info("skip bad transition from '$start_text' to '$end_text'");
                    next;
                }
            }
#        }

        $log->debug("set dialog from $start to $end");
        $text_txt->SetStyle($start, $end, $self->dialogue_style);
        push @valid_transitions, $start, $end;
    }

    $self->dialogue_transitions(\@valid_transitions);

    return;
}

################################################################################
sub check_for_changes { #{{{2
    my ($self) = @_;

    my $current_text = $self->control->{text_txt}->GetValue;
    my $checksum = sha1_hex($current_text);

    $log->debug("check_for_changes; now $checksum, saved " . $self->saved_checksum);
    return $checksum eq $self->saved_checksum
        ? 1
        : wxYES == Wx::MessageBox("Ok to lose changes?", "Lose Changes", wxYES_NO, $self->frame);
}

################################################################################
sub copy_to_html { #{{{2
    my ($frame) = @_;

    my $app = wxTheApp;
    my $text_txt = $app->control->{text_txt};
    (my $title = $text_txt->GetLineText(0)) =~ s/\s*\z//;

    my $html = <<"EOT";
<html>
<head>
<meta content="text/html; charset=ISO-8859-1"
http-equiv="content-type">
<title>$title</title>
</head>
<body>
EOT

    my $table_start = <<"EOT";
<table style="margin-left: 40px;" border="1" cellpadding="0" cellspacing="0">
<tbody>
<tr>
<td>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; </td>
<td style="background-color: #dddddd; font-weight: bold;"><b>
EOT

    my $table_end = "</b></td> </tr> </tbody> </table>";

    my @lines = split(/\n/, $text_txt->GetValue);
    my $offset = 0;
    my $dialogue_transitions = $app->dialogue_transitions;
    my $next_dialog_section = 0;
    my $is_dialog = 0;

    for my $line (@lines) {

        # watch for an offset matching the next section and change state

        if ($is_dialog && defined $dialogue_transitions->[$next_dialog_section + 1] && $offset > $dialogue_transitions->[$next_dialog_section + 1]) {
#            $log->info("dialog off at offset $offset");
            $is_dialog = 0;
            $next_dialog_section += 2;
        }

        if (! $is_dialog && defined $dialogue_transitions->[$next_dialog_section] && $offset == $dialogue_transitions->[$next_dialog_section]) {
#            $log->info("dialog on at offset $offset");
            $is_dialog = 1;
        }

#        $log->info("offset $offset $line, is_dialog: $is_dialog");
        $html .= $is_dialog
            ? $table_start . $line . $table_end . "\n"
            : $line . "<br>\n";

        # add 1 for LF
        $offset += length($line) + 1;
    }

#    $log->info("html: $html");

    $html .= "</body></html>\n";

    my $file_dialog = Wx::FileDialog->new($frame, "Save HTML to...", $app->current_dir, "$title.html", 'HTML files|*.html|All files|*', wxFD_SAVE);
    return unless $file_dialog->ShowModal == wxID_OK;
    my $filename = $file_dialog->GetPath;
    if (-f $filename) {
        return unless wxYES == Wx::MessageBox("File '$filename' exists; ok to overwrite?", "Confirm Overwrite", wxYES_NO, $frame);
    }

    write_file($filename, \$html);

#    if (wxTheClipboard->Open()) {
#        wxTheClipboard->SetData( Wx::TextDataObject->new($html) );
#        wxTheClipboard->Close();
#    }

    return;
}

################################################################################
sub search_text_forward { #{{{2
    my ($self, $search_expr) = @_;

    my $text_txt = $self->control->{text_txt};
    my $nbr_lines = $text_txt->GetNumberOfLines;
    my $pos = $text_txt->GetInsertionPoint;
    my ($column, $line) = $text_txt->PositionToXY($pos);

    $search_expr = quotemeta $search_expr;

    while ($line < $nbr_lines) {
        my $text = $text_txt->GetLineText($line);

        # are we on the cursor line?
        if ($column >= 0) {

            # remove everything up to and including the first char of the previous match
            substr($text, 0, $column + 1, '');
        }

        # minimal match of the preceding chunk here
        if ($text =~ /(.*?)?${search_expr}/i) {
            $column += length($1) + 1;
            my $start = $text_txt->XYToPosition($column, $line);
            my $end = $start + length($search_expr);
            $text_txt->SetSelection($start,$end);
            $text_txt->ShowPosition($start);
            $text_txt->SetFocus;
            return;
        }
        else {
            $line++;
            $column = -1;
        }
    }

    return;
}

################################################################################
sub OnInit { # {{{1
    my( $self ) = shift;

    Wx::InitAllImageHandlers();

    my $rc = $self->SUPER::OnInit();
    $log->debug("class init $rc");

    return 1;
}

################################################################################

sub OnExit { # {{{1
    my( $self ) = shift;

    return 1;
}

################################################################################

# main functions {{{1
package main;

################################################################################
sub assign_event_handler { #{{{2
    my ($control, $event, $handler) = @_;

#    $log->debug("handle $event for " . $self->name);

    my $event_type = "Wx::Event::$event";

    # find out how many args the event type needs to assign the handler
    my $arg_count = length prototype($event_type);

    my @controls = ($control);
    if ($arg_count == 3) {

        # 3 arg events need the parent as the first arg
        unshift @controls, $control->GetParent;
    }
    elsif ($arg_count == 4) {

        # the 4 arg version is used for handlers which affect a range of controls;
        # not modelled yet
        $log->logdie("no 4 arg events yet");
    }
    elsif ($arg_count != 2) {
        $log->logdie("bad event arg $arg_count");
    }

    # assign the handler
    {
        no strict 'refs';
        &{ $event_type }(@controls, $handler);
    }
}

# mainline {{{1

unless(caller) {

    # list of options
    my @options = qw(
        man
        usage
        debug
        file=s
        key=s
        quiet
        geometry=s
        script=s
    );

    my %option;

    GetOptions( \%option, @options ) or pod2usage(2);
    pod2usage(2) if $option{usage};
    pod2usage(1) if $option{help};
    pod2usage( -exitstatus => 0, -verbose => 2 ) if $option{man};

    # put this in %option
    $option{bin_dir} = $Bin;

    $ENV{log_appenders} = $option{quiet} ? 'file' : "file, screen";
    $ENV{log_level}     = $option{debug} ? "DEBUG" : 'INFO';
    $ENV{log_dir}       ||= $option{bin_dir};
    $ENV{log_file_name} ||= 'cedit';
    my $default_config = << "EOT" ;
log4perl.rootLogger=$ENV{log_level}, $ENV{log_appenders}

log4perl.appender.file=Log::Dispatch::FileRotate
log4perl.appender.file.filename=$ENV{log_dir}/$ENV{log_file_name}.log
# log4perl.appender.file.filename=/tmp/$ENV{log_file_name}.log
log4perl.appender.file.umask=0000
log4perl.appender.file.mode=append
log4perl.appender.file.layout=PatternLayout
log4perl.appender.file.size=10000000
log4perl.appender.file.max=3
log4perl.appender.file.layout.ConversionPattern=%d{MM-dd HH:mm:ss} [%p] %F{1} %L - %m%n

log4perl.appender.screen=Log::Log4perl::Appender::Screen
log4perl.appender.screen.layout=PatternLayout
log4perl.appender.screen.layout.ConversionPattern=%d{HH:mm:ss} [%p] %F{1} %L - %m%n
EOT

    my $log_config_file = $option{bin_dir} . '/log4perl.conf';
    if (-f $log_config_file) {
        Log::Log4perl->init( $log_config_file );
    }
    else {
        Log::Log4perl->init( \$default_config );
    }
    $log = get_logger();

    $log->debug("Running $0: " . Dumper(\%option));

    my $app = CeditApp->new(\%option);

#    if ($option{file}) {
#        $app->GetTopWindow->open_from_file(undef, $option{file});
#    }

    $app->MainLoop();

}

################################################################################

__END__

=head1

TODO

Everything

=cut
