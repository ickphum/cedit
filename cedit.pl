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
use List::MoreUtils;
use English qw(-no_match_vars);


# main variables {{{1

my $log;

my $Dictionary;

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
use YAML qw(Dump Load);
use English qw(-no_match_vars);

use TextListPopup;

__PACKAGE__->mk_accessors( qw(frame xrc filename key saved_checksum control current_dir cipher 
    cast
    frame_left _frame_top frame_width frame_height
    popup) 
    );

my $current_line_count;

sub new { # {{{2
    my( $class, $option ) = @_;
    my $self = $class->SUPER::new();

    die "No main.xrc" unless -f 'main.xrc';

    $self->xrc( Wx::XmlResource->new() );
    $self->xrc->InitAllHandlers;

    $self->xrc->Load('main.xrc');

    $self->frame( $self->xrc->LoadFrame(undef, 'main'));

    my $REFRESH_DICTIONARY_ID = 10000;

    Wx::Event::EVT_MENU($self->frame, wxID_NEW, \&new_file);
    Wx::Event::EVT_MENU($self->frame, wxID_OPEN, \&open_file);
    Wx::Event::EVT_MENU($self->frame, wxID_SAVE, \&save_file);
    Wx::Event::EVT_MENU($self->frame, $REFRESH_DICTIONARY_ID, sub { $log->info("refresh"); $self->load_dictionary; });
    Wx::Event::EVT_MENU($self->frame, wxID_ZOOM_IN, sub { $self->change_font_size(2); });
    Wx::Event::EVT_MENU($self->frame, wxID_ZOOM_OUT, sub { $self->change_font_size(-2); });
    Wx::Event::EVT_MENU($self->frame, wxID_SAVEAS, \&copy_to_html);
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
        [ wxACCEL_ALT,  ord('D'), $REFRESH_DICTIONARY_ID ],
    ));

    Wx::Event::EVT_SIZE($self->frame, sub {
        my ($frame, $event) = @_;
        
        my $size = $event->GetSize;
        $self->frame_width($size->GetWidth);
        $self->frame_height($size->GetHeight);
        $self->hide_popup;

        $event->Skip;
    });

    Wx::Event::EVT_MOVE($self->frame, sub {
        my ($frame, $event) = @_;
        
        my $pos = $event->GetPosition;
        $self->frame_left($pos->x);
        $self->frame_top($pos->y);
        $self->hide_popup;

        $event->Skip;
    });

    Wx::Event::EVT_CLOSE($self->frame, sub {
        my ($frame, $event) = @_;

        if ($self->check_for_changes) {
            $frame->Destroy;
        }
        else {
            $event->Veto;
        }
    });

    $self->control({});
    for my $child ( $self->frame->GetChildren ) {
        $log->debug("child $child " . $child->GetName);
        $self->control->{ $child->GetName } = $child;
    }

    my $text_txt = $self->control->{text_txt};
	
    if ($option->{night}) {
        $text_txt->SetBackgroundColour(wxBLACK);
        $text_txt->SetForegroundColour(wxWHITE);
    }

    $self->SetTopWindow($self->frame);
    $self->frame->Show(1);

    $self->current_dir($option->{bin_dir});

    # initialise a blank checksum so we know how long a checksum is
    $self->saved_checksum( sha1_hex('') );

    if ($option->{file}) {
        open_file($self->frame, undef, $option);
    }
    else {
        $text_txt->SetValue("Here's some sample text.\nNew line.\n\nNew paragraph\n\nA plain a b c 1 2 3 scalar is unquoted.\n\nAll plain scalars are automatic candidates for implicit tagging.\n\nThis means that their tag may be determined automatically by examination.\n\nThe typical uses for this are plain alpha strings, integers, real numbers, dates, times and currency.");
    }

    # have to do popup key processing in a EVT_KEY_DOWN handler because Win32 won't let
    # us ignore Return key events in EVT_CHAR, ie the newline gets added to the buffer
    # even if we don't Skip the event.
    Wx::Event::EVT_KEY_DOWN($text_txt, sub {
        my ($frame, $event) = @_;
        my $keycode = $event->GetKeyCode;

        # if the popup is displayed, either process a valid key for it or cancel it before we do anything else
        if ($self->popup) {
            my $close_popup;
            my $skip_key;
            if ($keycode == WXK_UP || $keycode == WXK_DOWN) {
                $self->popup->navigate_by_key($keycode);
                $skip_key = 1;
            }
            elsif ($keycode == WXK_RETURN) {
                $self->popup->select_entry;
                $close_popup = 1;
                $skip_key = 1;               
            }
            else {
                $close_popup = 1;
            }
            if ($close_popup) {
                $self->hide_popup;
            }
            return if $skip_key;
        }

        $event->Skip;
        return;
    });

    $current_line_count = $text_txt->GetNumberOfLines;
    Wx::Event::EVT_CHAR($text_txt, sub {
        my ($frame, $event) = @_;

        my $text_txt = $event->GetEventObject;

        my ($keycode, $shift_down, $ctrl_down, $alt_down) = ($event->GetKeyCode, $event->ShiftDown, $event->ControlDown, $event->AltDown);

        my ($selection_from, $selection_to) = $text_txt->GetSelection;
        my $selected_text = $text_txt->GetStringSelection;
        my $selection_length = $selection_to - $selection_from;
        my $current_location = $text_txt->GetInsertionPoint;
        my $end_of_text = $text_txt->GetLastPosition;

        # on Windows, handle the 'feature' by which double-clicking on a word selects the
        # word and the following space, but if a printable character is entered, the space is not removed
        # with the rest of the selection. 
        if ($selection_length > 1 && $keycode >= 32 && $keycode <= 126 && $OSNAME =~ /Win32/ && $selected_text =~ /\s\z/) {
            $selection_length--;
        }

        my $autotext;
        my $no_wx_key_processing = 0;

#        if ($shift_down) {
#            if ($keycode == 32) {
#
#                # find the word before the cursor
#                my $index = $current_location;
#                my $word = '';
#                while ($index > 0) {
#                    my $char = $text_txt->GetRange($index-1, $index);
#                    last if ord $char <= 32;
#                    $word = "${char}${word}";
#                    $index--;
#                }
#
#                if (my $popup = TextListPopup::create_popup($frame, $text_txt, $Dictionary, $word)) {
#                    $self->popup($popup);
#                    $no_wx_key_processing = 1;
#                }
#            }
#        }
        
        my $app = wxTheApp;
        my $autoword_lbx = $app->control->{autoword_lbx};

        # refresh auto list after every printable char
        if (($keycode > WXK_SPACE && $keycode < WXK_DELETE) || $keycode == WXK_BACK) {

            # find the word before the cursor
            my $index = $current_location;
            my $word = '';
            while ($index > 0) {
            
                my $char = $text_txt->GetRange($index-1, $index);
                last if ord $char <= 32;
                $word = "${char}${word}";
                $index--;
            }

            if ($keycode == WXK_BACK) {

                # backspace so lose final char in word
                $word =~ s/.$//;
            }
            else {

                # we just added a char so add that to the word
                $word .= chr($keycode);
            }
			
			# remove all non-alpha chars, mainly to stop unmatched regex symbols blowing up
			$word =~ s/[^A-Za-z]//g;

            if ((length $word >= 2) || $word =~ /\A[A-Z]/) {

                # display dictionary matches
                my $dictionary_group = $Dictionary->{ substr($word,0,2) };
#                $log->info("dictionary_group " . Dumper($dictionary_group));
#                $log->info("sorted dictionary_group " . Dumper( [ sort { $dictionary_group->{$a} <=> $dictionary_group->{$b} } keys %{ $dictionary_group }]));
                my @matches = $dictionary_group
                    ? length $word > 2
                        ? sort { $dictionary_group->{$b} <=> $dictionary_group->{$a} } grep { /\A$word/ } keys %{ $dictionary_group }
                        : sort { $dictionary_group->{$b} <=> $dictionary_group->{$a} } keys %{ $dictionary_group }
                    : ();
#                my $list = length $word > 2
#                    ? [ grep { /\A$word/ } @{ $Dictionary->{$prefix} || [] } ]
#                    : $Dictionary->{$prefix} || [];
                $autoword_lbx->Set(\@matches);
                $autoword_lbx->SetSelection(0) if @matches;
            }
        }
        elsif (! $alt_down) {

            # don't clear if we pressed an alt-key in case we're using the autotext box
            $autoword_lbx->Clear;
        }
        
        if ($alt_down) {
            if ($keycode == WXK_UP || $keycode == WXK_DOWN) {
                if (my $count = $autoword_lbx->GetCount) {
                    my $new_selection = $autoword_lbx->GetSelection + ($keycode == 315 ? -1 : 1);
                    if ($new_selection >= 0 && $new_selection < $count) {
                        $autoword_lbx->SetSelection($new_selection);
                    }
                }
            }
            elsif ($keycode == WXK_LEFT || $keycode == WXK_RIGHT) {
                if (my $selected_word = $autoword_lbx->GetStringSelection) {

                    # find the word before the cursor
                    my $index = $current_location;
                    my $word = '';
                    while ($index > 0) {
                    
                        my $char = $text_txt->GetRange($index-1, $index);
                        last if ord $char <= 32;
                        $word = "${char}${word}";
                        $index--;
                    }

                    ($autotext = $selected_word) =~ s/$word//;
                    # $autotext .= ' ';
                }
            }
            elsif (my $cast = $self->cast) {
                my $char = uc(chr($keycode));
                if ($cast->{$char}) {
                    $log->debug("insert name " . $cast->{$char});
                    $autotext = $cast->{$char} . ($shift_down ? "'s " : ' ');
                }
                else {
                    $log->info("ignore, no $char ($keycode) in cast.");
                }
            }
        }

        if ($autotext) {
            $self->add_string($autotext);

            # don't process the char if we found autotext applicable to it
            $no_wx_key_processing = 1;
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

        my $input_length = $autotext
            ? length($autotext)                         # some kind of autotext shortcut we're adding directly to the control
            : ($keycode >= 32 && $keycode <= 126) || $keycode == 13
                ? 1                                     # printable chars
                : $keycode == 8                         # backspace
                    ? $selection_length || $current_location == 0
                        ? 0                             # with selection or at start of buffer, 0 chars inserted
                        : -1                            # otherwise, one char removed
                    : $keycode == 127                   # delete
                        ? $selection_length || $current_location == $end_of_text
                            ? 0                         # with selection or at end of buffer, 0 chars inserted
                            : -1                        # otherwise, one char removed
                        : $keycode == 24
                            ? 0                         # cut always adds 0 chars, may remove selection
                            : $keycode == 22
                                ? $clipboard_length     # paste
                                : undef;                # all other keys don't change the buffer

        $event->Skip unless $no_wx_key_processing;

        # refresh dictionary after every word
        $self->load_dictionary if $keycode == WXK_SPACE || $keycode == WXK_RETURN;

        return;
    });

    return $self;
}

################################################################################
sub add_string { #{{{2
    my ($self, $string) = @_;

    $self->control->{text_txt}->WriteText($string);

    return;
}

################################################################################
sub frame_top { #{{{2
    my ($self, $top) = @_;

    if (defined $top) {
        $self->_frame_top($top);
        return $top;
    }
    else {
        my $real_top = $self->_frame_top;
        return $real_top + 27;
    }
}

################################################################################
sub hide_popup { #{{{2
    my ($self) = @_;

    if ($self->popup) {
        $log->info("close popup");
        $self->popup->Hide;
        $self->popup->Destroy;
        $self->popup(undef);
    }
}

################################################################################
# Just clear the text control and the filename and key attributes
sub new_file { #{{{2
    my ($no_check) = @_;

    my $app = wxTheApp;
    unless ($no_check) {
        return unless $app->check_for_changes;
    }

    $app->control->{text_txt}->Clear;
    $app->{filename} = undef;
    $app->saved_checksum( sha1_hex('') );
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
        font_size => $text_txt->GetFont->GetPointSize,
        left => $left,
        top => $top,
        width => $width,
        height => $height,
    });

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

    $log->debug("open from $filename");
    my $file_text = read_file($filename, binmode => ':raw');

    if ($filename =~ /\.ced\z/) {

        my $key = $option->{key};
        unless ($key) { 
            return unless $key = Wx::GetPasswordFromUser("Enter key", "Key Entry", "", $frame);
        }
        $app->cipher( Crypt::CBC->new( -key => $key, -cipher => 'Blowfish') );

        # the file text contains the checksum of the plaintext, so we can warn about incorrect keys.
        # Assume that all checksums will be the same length (until we do something silly like change the checksum method).
        my $checksum_length = length $app->saved_checksum;

        my $file_checksum = substr($file_text, 0, $checksum_length, '');

        # remove and unpack the yaml chunk
        my $yaml_length = unpack('S', substr($file_text, 0, 2, ''));
        my $yaml = substr($file_text, 0, $yaml_length, '');

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

        if ($edit_text =~ /^Cast: ([-a-z_ ]+)/i) {
            my $cast_str = $1;
            my @names = split(/ /, $cast_str);
			map { s/_/ /g } @names;
            my $cast = { map { substr($_, 0,1,) => $_ } @names };
            $app->cast($cast);
            $log->info("cast: $cast_str = " . Dumper(\@names, $cast));
        }

        $app->load_dictionary;

        # apply the properties
        $app->change_font_size(0, $property->{font_size});
        $frame->SetSize($property->{width}, $property->{height});
        $log->info("move to $property->{left}, $property->{top}");
        $frame->Move([ $property->{left}, $property->{top} ]);

        # set once open is successful
        $app->saved_checksum($edit_checksum);
        $app->key($key);
        $app->filename($filename);
    }
    else {

        # assume any non-ced file is plain text
        new_file('no check for changes');

        $file_text =~ s/[^\x00-\x7f]/?/g;

        $app->control->{text_txt}->SetValue( $file_text );
    }

    return;
}

################################################################################
sub load_dictionary { #{{{2
    my ($self) = @_;

    my $text = $self->control->{text_txt}->GetValue;
#    my @words = List::MoreUtils::uniq sort grep { length($_) > 3 } split(/\s+|[,."!?()&:;]/, $text);
    my @words = grep { length($_) > 3 } split(/\s+|[,."!?()&:;]/, $text);

    $log->debug("load_dictionary; " . scalar @words);

    $Dictionary = {};

    for my $word (@words) {
        my $group = $Dictionary->{ substr($word,0,2) } ||= {};
        $group->{ $word }++;
#        $Dictionary->{ substr($word,0,2) } ||= [];
#        push @{ $Dictionary->{ substr($word,0,2) } }, $word;
    }

    # add the cast names as special lists under their initial letter
    if (my $cast = $self->cast) {
        for my $initial (keys %{ $cast }) {
            $Dictionary->{$initial} = { $cast->{$initial} => 2, $cast->{$initial} . "'s" => 1 };
        }
    }

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

#    $self->refresh_dialogue_styles;

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

    $text_txt->SetInsertionPoint($start);
    $text_txt->WriteText('"');

#    # go forward to next LF
#    while ($end <= $#chars && $chars[$end] != 10) {
#        $end++;
#    }

#    my $style;
#    my $dialogue_transitions = $self->dialogue_transitions;
#
#    # find the highest transition less than or equal to the current position;
#    # we need this whether we're setting or clearing.
#    # Do this manually rather than via List::MoreUtils because we know the list is sorted
#    # and can stop earlier.
#    my $active_transition_index = -1;
#    for my $i (0 .. $#{ $dialogue_transitions }) {
#
#        # we match on the start but before the end, otherwise we match the end of the
#        # currrent transition when we're at the end of a styled line.
#        if (($i % 2 == 0 && $dialogue_transitions->[$i] <= $cursor_pos) 
#            || ($i % 2 && $dialogue_transitions->[$i] < $cursor_pos))
#        {
#            $active_transition_index = $i;
#        }
#        else {
#            last;
#        }
#    }
#
#    if ($switch_on) {
#        $style = $self->dialogue_style;
##        $self->dialogue_line->{ $line_nbr } = 1;
#
#        # the last transition (if any) should be a switch off, hence an odd index
#        if ($active_transition_index >= 0 && ($active_transition_index % 2 == 0)) {
#            $log->info("switch on inside an existing transition: $cursor_pos, $active_transition_index, " . Dumper($dialogue_transitions));
#            return;
#        }
#
#        # add after previous transition or at start if none
#        $active_transition_index++;
#        splice @{ $dialogue_transitions }, $active_transition_index, 0, $start, $end;
#    }
#    else {
#        $style = $self->default_style;
##        delete $self->dialogue_line->{ $line_nbr };
#
#        # the last transition should be a switch on, hence an even index
#        if ($active_transition_index < 0 || $active_transition_index % 2) {
#            $log->info("switch off outside an existing transition: $cursor_pos, $active_transition_index, " . Dumper($dialogue_transitions));
#            return;
#        }
#
#        # remove this transition
#        splice @{ $dialogue_transitions }, $active_transition_index, 2;
#
#    }
#
##    $log->info("dialogue_transitions now " . Dumper($dialogue_transitions));
#    $self->dialogue_transitions($dialogue_transitions);
#    $text_txt->SetStyle($start, $end, $style);
#
    return;
}
################################################################################
#sub shift_dialogue_styles { #{{{2
#    my ($self, $increment) = @_;
#
#    my $text_txt = $self->control->{text_txt};
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
#
################################################################################
# Note that this won't take off any styles, so it only works after a load or a font
# size change.
#sub refresh_dialogue_styles { #{{{2
#    my ($self) = @_;
#
#    my @caller = caller(1);
#
#    my $text_txt = $self->control->{text_txt};
#    my $last_position = $text_txt->GetLastPosition;
#    $text_txt->SetStyle(0, $last_position, $self->default_style);
#    my $full_text = $text_txt->GetValue;
#
#    my $transitions = $self->dialogue_transitions;
#    my $count = $#{ $transitions } + 1;
#    if ($count % 2) {
#        $log->die("transitions has odd number of chars : " . Dumper($transitions));
#    }
#    my $i = 0;
#    my @valid_transitions = ();
#    while ($i < $count) {
#        my $start = $transitions->[$i];
#        my $end = $transitions->[$i + 1];
#        $i += 2;
##        if ($i < 10) {
#            my $start_text = substr $full_text, $start-2, 5;
#            my $end_text = substr $full_text, $end-2, 5;
#            my @start_chars = unpack('C*', $start_text);
#            my @end_chars = unpack('C*', $end_text);
##            $log->info("offset $i, $start to $end, chars = @start_chars to @end_chars");
#            if (@start_chars == 5 && @end_chars == 5) {
#                if ($start_chars[1] != 10 || $end_chars[2] != 10) {
#                    $log->info("skip bad transition from '$start_text' to '$end_text'");
#                    next;
#                }
#            }
##        }
#
#        $log->debug("set dialog from $start to $end");
#        $text_txt->SetStyle($start, $end, $self->dialogue_style);
#        push @valid_transitions, $start, $end;
#    }
#
#    $self->dialogue_transitions(\@valid_transitions);
#
#    return;
#}

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

    my $dialog_1_start = "<strong> &nbsp;&nbsp;\n";
    my $dialog_1_end = "</strong><br>\n";

    my $dialog_2_start = "<i> &nbsp;&nbsp;&nbsp;&nbsp;\n";
    my $dialog_2_end = "</i><br>\n";

    my $image_tag = '<IMG SRC="clouds.jpg">';

    my @lines = split(/\n/, $text_txt->GetValue);

    for my $line (@lines) {

        $html .= $line =~ /\A"(.*)/
            ? $dialog_1_start . $1 . $dialog_1_end . "\n"
            : $line =~ /\A\{(.*)/
                ? $dialog_2_start . $1 . $dialog_2_end . "\n"
                : $line . "<br>\n";

    }

    $html .= "</body></html>\n";

    my $file_dialog = Wx::FileDialog->new($frame, "Save HTML to...", $app->current_dir, "$title.html", 'HTML files|*.html|All files|*', wxFD_SAVE);
    return unless $file_dialog->ShowModal == wxID_OK;
    my $filename = $file_dialog->GetPath;
    if (-f $filename) {
        return unless wxYES == Wx::MessageBox("File '$filename' exists; ok to overwrite?", "Confirm Overwrite", wxYES_NO, $frame);
    }

    write_file($filename, \$html);

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

    $app->MainLoop();

}

################################################################################

__END__

=head1

TODO

Everything

=cut
