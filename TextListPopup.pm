# $Id: TextListPopup.pm 2103 2016-08-25 00:54:14Z ikm $
use Wx 0.15 qw[:allclasses];
package TextListPopup;

use strict;
use base qw(Wx::PopupWindow Class::Accessor::Fast);

use Wx qw[:everything];
#use Wx::Event qw(EVT_PAINT EVT_MOTION EVT_LEFT_DOWN);
use Log::Log4perl qw(get_logger);
use Data::Dumper;
use English qw(-no_match_vars);

# attributes {{{1

__PACKAGE__->mk_accessors(qw(bitmap color pen brush 
    scrollbar_displayed scrollbar_button_width scrollbar_button_height
    scrollbar_handle_offset scrollbar_handle_size scrollbar_handle_max_offset
    scrollbar_page_size scrollbar_previous_y first_text_index pixels_per_line max_index_displayed
    frame text_ctrl text_list_strings text_list_index prefix));

# private globals {{{1

my $Max_index = 9;

my $log = get_logger();

#my $Text_list_strings;
#my $Text_list_index;

# functions {{{1

################################################################################
sub new { #{{{2
    my($class, $parent ) = @_;

    # the constructor doesn't take any useful args eg size, name, etc
    my $self = $class->SUPER::new( $parent );

    $self->bitmap({});
#    for my $bitmap (qw(text_list_arrow_up text_list_arrow_down)) {
#        my $bitmap_path = File::Spec->catfile(Wax::get_wax_dir(), 'resource', 'images', "$bitmap.png");
#        $log->logdie("no bitmap file $bitmap_path") unless -f $bitmap_path;
#        $self->bitmap->{$bitmap} = Wx::Bitmap->new($bitmap_path, wxBITMAP_TYPE_ANY)
#            or $log->logdie("couldn't create bitmap for $bitmap");
#    }
#
#    $self->scrollbar_button_width( $self->bitmap->{text_list_arrow_up}->GetWidth );
#    $self->scrollbar_button_height( $self->bitmap->{text_list_arrow_up}->GetHeight );

#    $self->scrollbar_displayed(1);
#    $self->scrollbar_previous_y(-1);
    $self->first_text_index(0);

    my %color = (
        background          => '#fefeca',
#        scrollbar_border    => '#838243',
#        scrollbar_handle    => '#f2f391',
#        scrollbar_shine     => '#ffffd5',
#        scrollbar_shadow    => '#d8d969',
#        scrollbar_trough    => '#e5e6a4',
        row_hilite_from     => '#c4d3e8', 
        row_hilite_to       => '#939af1',
    );

    $self->color({});
    $self->pen({});
    $self->brush({});
    for my $color_name (keys %color) {
        $self->color->{$color_name} = Wx::Colour->new($color{$color_name});
        $self->pen->{$color_name} = Wx::Pen->new($self->color->{$color_name}, $color_name =~ /scrollbar_sh/ ? 2 : 1, wxSOLID);
        $self->brush->{$color_name} = Wx::Brush->new($self->color->{$color_name}, wxSOLID);
    }

    return $self;
}

################################################################################
# Create a popup window with matches for the specified value.
sub create_popup { #{{{2
    my ($frame, $text_ctrl, $dictionary, $prefix) = @_;

    $log->info("create_popup '$prefix'");

    return unless length $prefix > 1;
    my $candidates = $dictionary->{ substr($prefix,0,2) };

    my $text_list_strings = [ grep { /\A${prefix}\w/ } @{ $candidates } ];

    return unless @{ $text_list_strings };

    my $max_index_displayed;
    if ($#{ $text_list_strings } > $Max_index) {

        # initial max index is screen size since first == 0; this is recalculated on scroll
        $max_index_displayed = $Max_index;
    }
    else {
        $max_index_displayed = $#{ $text_list_strings };
    }

    # default popup position is just under text control position, but 
    # switch to above it if the control is low on the screen
    my $screen_width = Wx::SystemSettings::GetMetric(wxSYS_SCREEN_X);
    my $screen_height = Wx::SystemSettings::GetMetric(wxSYS_SCREEN_Y);
    # $log->info("screen $screen_width x $screen_height, display_text_list for $text_ctrl from " . AG::Util::get_caller);
    my $popup_height = ($Max_index+1) * 15 + 6;
    
    my $app = wxTheApp;
    my @pos = ($app->frame_left, $app->frame_top);
    my @size = ($app->frame_width, $app->frame_height);

    # create popup if needed
    my $popup; 
    if ($popup) {

        # TODO we should move automatically in the Window's move and size events
        $popup->Move(@pos);
    }
    else {

        $popup = TextListPopup->new($text_ctrl);
        Wx::Event::EVT_PAINT($popup, \&TextListPopup::text_list_paint);
        # Wx::Event::EVT_MOTION($popup, \&TextListPopup::text_list_mouse_motion);
        # Wx::Event::EVT_LEFT_DOWN($popup, \&TextListPopup::text_list_left_down);
        # Wx::Event::EVT_LEFT_UP($popup, \&TextListPopup::text_list_left_up);
        
        $log->info("app size @size, pos @pos");

#        $popup->Move($pos[0] + $size[0] - 200, $pos[1] + 32);
        $popup->Move($size[0] - 200, 0);
        $popup->SetSize(200, $size[1] - 58);
        $popup->Show;
        $popup->frame($frame);
        $popup->text_ctrl($text_ctrl);
    }

    $popup->max_index_displayed($max_index_displayed);
    $popup->text_list_strings($text_list_strings);
    $popup->text_list_index(0);
    $popup->prefix($prefix);

    $popup->Refresh;
    return $popup;
}

################################################################################
# EVT_TEXT handler for text controls with dynamic lists.
# Recalculate the list and display the popup after each change to the value.
#sub display_text_list { # {{{2
#    my ($screen, $event) = @_;
#
#    my $text_ctrl = $event->GetEventObject;
#    my $focus_ctrl = Wx::Window::FindFocus;
#    if (! $focus_ctrl || $text_ctrl != $focus_ctrl) {
#        $event->Skip;
#        return;
#    }
#
#    my $value = $text_ctrl->GetValue;
#    if (length $value >= ($wax_control->text_list_min_chars || 1)) {
#        create_popup($screen, $text_ctrl, $value);
#    }
#    else {
#
#        if (my $popup = $wax_control->text_list_popup) {
#            $log->info("destroy, no value in field");
#            $popup->Hide;
#            $popup->Destroy;
#            $wax_control->text_list_popup(undef);
#        }
#    }
#
#    $event->Skip;
#
#    return;
#}

################################################################################
# Make a selection from the list
sub select_entry { #{{{2
    my ($self) = @_;

    my $index = $self->text_list_index;
    my $new_value = $self->text_list_strings->[$index];
    my $prefix_length = length $self->prefix;
    
    $log->info("select $new_value from $index");

    wxTheApp->add_string(substr($new_value, $prefix_length) . ' ');

    return;
}

################################################################################
# Paint the text list
sub text_list_paint { #{{{2
    my( $self, $event ) = @_;

    my $app = wxTheApp;

    my $dc = Wx::PaintDC->new( $self );

    $dc->SetBrush( $self->brush->{background} );
    $dc->SetPen( wxBLACK_PEN );
    my ($width, $height) = ($self->GetSize->x, $self->GetSize->y);

    $dc->DrawRectangle( 0, 0, $width, $height );
    my $font = $dc->GetFont;

    # wx3 uses a different default font size; just set specific size for now
    $font->SetPointSize(11);
    $dc->SetFont($font);

    my @text_strings = @{ $self->text_list_strings };
    my $text_list_index = $self->text_list_index;

    my $first_text_index = $self->first_text_index;
    for my $i (0 .. $Max_index) {
        last if $i + $first_text_index > $#text_strings;
        if ($i + $first_text_index == $text_list_index) {
            $dc->GradientFillLinear(Wx::Rect->new(1,$i * 15 + 1, $width - 2, 15), $self->color->{row_hilite_from}, $self->color->{row_hilite_to}, wxSOUTH);
        }
        $dc->DrawText($text_strings[$i + $first_text_index], 2, $i * 15);
    }

    return;
}

################################################################################
# EVT_CHAR handler for text fields with dynamic lists.
# Handle special characters, eg arrows, home, end, pgup etc, & Return for selection
sub navigate_by_key { #{{{2
    my ($self, $code) = @_;

    my $text_list_index = $self->text_list_index;
    
    if ($code == WXK_UP) {
        if ($text_list_index > 0) {

            $self->text_list_index($text_list_index-1);

        }

    }
    elsif ($code == WXK_DOWN) {
        my $last_list_index = $#{ $self->text_list_strings };
        if ($text_list_index < $last_list_index) {
            $self->text_list_index($text_list_index+1);
        }
    }

    $self->Refresh;

    return;
}

################################################################################
sub set_scrollbar_handle_offset { #{{{2
    my ($self, $new_offset) = @_;

    my $scrollbar_handle_max_offset = $self->scrollbar_handle_max_offset;

    # apply offset limits
    if ($new_offset < 0) {
        $new_offset = 0;
    }
    elsif ($new_offset > $scrollbar_handle_max_offset) {
        $new_offset = $scrollbar_handle_max_offset;
    }
    $self->scrollbar_handle_offset($new_offset);

    my $first_text_index = 0;
    if ($new_offset > 0) {
        my $pixels_per_line = $self->pixels_per_line;
        $first_text_index = int(($new_offset + $pixels_per_line / 2) / $pixels_per_line); 
    }

    $self->first_text_index($first_text_index);

    # we're assuming that this is only called when the scrollbar is displayed, and so
    # we always display a full screen of items, and so we don't care how many strings are in
    # the list
    my $max_index_displayed = $first_text_index + $Max_index;
    $self->max_index_displayed($max_index_displayed);

    return;
}

################################################################################
# Handle mouse movement over the text list
sub text_list_mouse_motion { #{{{2
    my( $self, $event ) = @_;

    my ($x,$y) = ($event->GetX,$event->GetY);
    my $screen = wxTheApp->current_screen;
    my $wax_control = $screen->control_from_widget->{$self->GetParent};
    my $new_index = int(($y - 1) / 15);
    my $first_text_index = $self->first_text_index;
    my $max_index_displayed = $self->max_index_displayed;

    if (($new_index + $first_text_index) <= $max_index_displayed) {
        $wax_control->text_list_index($new_index + $first_text_index);
#        $log->info("new_index $new_index, first_text_index $first_text_index, max_index_displayed $max_index_displayed, text_list_index " . $wax_control->text_list_index);

        my $scrollbar_previous_y = $self->scrollbar_previous_y;
        if ($scrollbar_previous_y >= 0) {
            $self->set_scrollbar_handle_offset($self->scrollbar_handle_offset + ($y - $scrollbar_previous_y));

            # don't let previous y go -ve or we terminate the scrolling
            $self->scrollbar_previous_y($y < 0 ? 0 : $y);
        }

        $self->Refresh;
    }

    $event->Skip;
    return;
}

################################################################################
# Handle left click on the text list, ie stop scrolling
sub text_list_left_up { #{{{2
    my( $self, $event ) = @_;

    $self->scrollbar_previous_y(-1);

    $event->Skip;

    return;
}

################################################################################
# Handle left click on the text list, ie for selection and scrolling
sub text_list_left_down { #{{{2
    my( $self, $event ) = @_;

    my $screen = wxTheApp->current_screen;
    my $wax_control = $screen->control_from_widget->{$self->GetParent};
    my ($x,$y) = ($event->GetX,$event->GetY);
    my ($width,undef) = $self->GetSizeWH;

    if ($self->scrollbar_displayed && $x > ($width - ( $self->scrollbar_button_width + 2))) {
#        $log->info("scrollbar at $x,$y");

        my $scrollbar_handle_offset = $self->scrollbar_handle_offset;
        my $scrollbar_handle_max_offset = $self->scrollbar_handle_max_offset;
        my $scrollbar_handle_size = $self->scrollbar_handle_size;

        if ($y < ($scrollbar_handle_offset+3)) {
#            $log->info("page up");
            $scrollbar_handle_offset -= $scrollbar_handle_size;
        }
        elsif ($y > ($scrollbar_handle_offset + $scrollbar_handle_size + 2)) {
#            $log->info("page down");
            $scrollbar_handle_offset += $scrollbar_handle_size;
        }
        else {
#            $log->info("on handle");
            $self->scrollbar_previous_y($y);
        }

        $self->set_scrollbar_handle_offset($scrollbar_handle_offset);
        $self->Refresh;
    }
    else {

        # are we over a valid item?
        my $new_index = int(($event->GetY - 1) / 15) + $self->first_text_index;
        if ($new_index <= $self->max_index_displayed) {
            $self->select_entry($screen, $wax_control, $new_index);
            return;
        }
    }

    $event->Skip;
    return;
}

1;
