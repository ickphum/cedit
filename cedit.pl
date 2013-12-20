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

# CeditXRCHandler {{{1

# we need a custom handler to support richText controls

package CeditXRCHandler;

use strict;
use warnings;

use Wx qw(:everything);
use Wx::XRC;
use Wx::FS;
use Wx::RichText;
use Alien::wxWidgets;

use Data::Dumper;

use base 'Wx::PlXmlResourceHandler';

################################################################################
sub constructor_args { #{{{2
    my ($self) = @_;

    # this seems universal
    my @args = (
        $self->GetParentAsWindow,
        $self->GetID,
    );

    if ($self->{class} eq 'wxRichTextCtrl') {
        push @args, 
            $self->GetText('value'),
            $self->GetPosition,
            $self->GetSize,
            $self->GetStyle( "style", 0 );
    }
    else {
        $log->logdie("unhandled class $self->{class}");
    }

    return @args;
}

################################################################################
# this method must return true if the handler can handle the given XML node
sub CanHandle { #{{{2
    my ($self, $xmlnode) = @_;
    my $property = Alien::wxWidgets->version >= 2.009
        ? $xmlnode->GetAttributes
        : $xmlnode->GetProperties;
    while ($property) {

        # add the properties to the object itself; I couldn't get the class in DoCreateResource()
        # without this
        $self->{$property->GetName()} = $property->GetValue;
        $property = $property->GetNext;
    }

    my $rc = $self->{class} =~ /wxRichTextCtrl/ ? 1 : 0;

    $log->debug("CanHandle $self->{class} : $rc");

    return $rc;
}

################################################################################
# this method is where the actual creation takes place; it has access to the custom properties
# for the object via GetText(), GetColour(), etc.
sub DoCreateResource { #{{{2
    my ($self) = shift;

    die 'LoadOnXXX not supported by this handler' if $self->GetInstance;

    my $app = wxTheApp;

    # get the control's name, ie the 'Id name' property in DialogBlocks
    my $control_name = $self->GetName;

    $log->debug("DoCreateResource: $control_name, $self->{class}, parent class: " . ref $self->GetParentAsWindow);

    (my $control_class = $self->{class}) =~ s/wx/Wx::/;

    # get the constructor arg list for this class
    my @constructor_args = $self->constructor_args;

    $log->debug("build $control_name which is a $self->{class} ($control_class), args = " . Dumper(\@constructor_args));

    # build the control and any controls contained inside it; this could call us recursively
    my $control = $control_class->new( @constructor_args );

    $self->SetupWindow( $control );
    $self->CreateChildren( $control );

    $control->SetName($control_name);

#    $log->debug("completed $control_name");
    return $control;
}

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

__PACKAGE__->mk_accessors( qw(frame xrc filename key saved_checksum control current_dir cipher 
    default_style dialogue_style dialogue_line) 
    );

my $current_line_count;

sub new { # {{{2
    my( $class, $option ) = @_;
    my $self = $class->SUPER::new();

    $self->xrc( Wx::XmlResource->new() );
    $self->xrc->InitAllHandlers;
#    my $custom_xrc_handler = CeditXRCHandler->new ;
#    $custom_xrc_handler->AddStyle('wxWANTS_CHARS', wxWANTS_CHARS);
#    $self->xrc->AddHandler($custom_xrc_handler);

    $self->xrc->Load('main.xrc');

    $self->frame( $self->xrc->LoadFrame(undef, 'main'));

    Wx::Event::EVT_MENU($self->frame, wxID_NEW, \&new_file);
    Wx::Event::EVT_MENU($self->frame, wxID_OPEN, \&open_file);
    Wx::Event::EVT_MENU($self->frame, wxID_SAVE, \&save_file);
    Wx::Event::EVT_MENU($self->frame, wxID_ZOOM_IN, sub { $self->change_font_size(2); });
    Wx::Event::EVT_MENU($self->frame, wxID_ZOOM_OUT, sub { $self->change_font_size(-2); });
    Wx::Event::EVT_MENU($self->frame, wxID_HELP, sub { $self->toggle_dialogue_style; });
    Wx::Event::EVT_MENU($self->frame, wxID_DOWN, sub { $self->shift_dialogue_styles(1); });
    Wx::Event::EVT_MENU($self->frame, wxID_UP, sub { $self->shift_dialogue_styles(-1); });
    Wx::Event::EVT_MENU($self->frame, wxID_SAVEAS, \&copy_to_html);
    Wx::Event::EVT_MENU($self->frame, wxID_REFRESH, 
        sub {

            # ShowPosition puts the specified position at the bottom of the window, so find out
            # what position is there now.
            my $text_txt = wxTheApp->control->{text_txt};
            my (undef, $height) = $text_txt->GetSizeWH;
            my ($status, $column, $row) = $text_txt->HitTest([0,$height - 10]);
            my $position = $text_txt->XYToPosition($column, $row);

            # fake a font size change to refresh the styles
            $self->change_font_size(1);
            $self->change_font_size(-1);

            # show previous position
            $text_txt->ShowPosition($position);

            return;
        });

    $self->frame->SetAcceleratorTable( Wx::AcceleratorTable->new (
        [ wxACCEL_CTRL, ord('S'), wxID_SAVE ],
        [ wxACCEL_CTRL, ord('D'), wxID_HELP ],
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
        ($width, $height, $left, $top) = (500,400,400,400);
    }
    $log->debug("screen geom $width x $height @ $left, $top");
    $self->frame->SetSize($left, $top, $width, $height);

    $self->control({});
    for my $child ( $self->frame->GetChildren ) {
        $log->debug("child $child " . $child->GetName);
        $self->control->{ $child->GetName } = $child;
    }

    my $text_txt = $self->control->{text_txt};

    $self->SetTopWindow($self->frame);
    $self->frame->Show(1);

    $self->current_dir($option->{bin_dir});
    $self->saved_checksum( sha1_hex('') );

    my $dialogue_style = Wx::TextAttr->new(wxBLACK, Wx::Colour->new('#dddddd'));
    $dialogue_style->SetLeftIndent(100);
    $self->dialogue_style($dialogue_style);
    my $default_style = Wx::TextAttr->new($text_txt->GetForegroundColour, wxWHITE);
    $default_style->SetLeftIndent(0);
    $self->default_style($default_style);
    $self->dialogue_line({});

    if ($option->{file}) {
        open_file($self->frame, undef, $option->{file});
    }

    $current_line_count = $text_txt->GetNumberOfLines;
    Wx::Event::EVT_TEXT($self->frame, $text_txt, sub {
        my ($frame, $event) = @_;

        $event->Skip;

        my $text_txt = $event->GetEventObject;
        my $line_count = $text_txt->GetNumberOfLines;
        if (my $change = ($line_count - $current_line_count)) {

            # this event fires on any change, ie block delete, etc;
            # we only want to fire on single line changes.
            $self->shift_dialogue_styles($change) if abs($change) == 1;
        }
        $current_line_count = $line_count;

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

        my $key;
        while (1) {
            return unless $key = Wx::GetPasswordFromUser("Choose key", "Key Entry", "", $frame);
            return unless my $confirm_key = Wx::GetPasswordFromUser("Confirm key", "Key Entry", "", $frame);

            last if $key eq $confirm_key;

            Wx::MessageBox("The keys do not match.", "No Match", wxOK, $frame);
        }

        $app->filename( $filename );
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
        dialogue_line => $app->dialogue_line,
        font_size => $text_txt->GetFont->GetPointSize,
        left => $left,
        top => $top,
        width => $width,
        height => $height,
    });

    # save the checksum so we can identify wrong keys
    my $file_text = $checksum . pack('S', length $yaml) . $yaml . $app->cipher->encrypt($edit_text);

    write_file($filename, \$file_text);

    $log->info("save to $filename");

    return;
}

################################################################################
sub open_file { #{{{2
    my ($frame, $event, $filename) = @_;

    my $app = wxTheApp;
    return unless $app->check_for_changes;

    unless ($filename) {

        my $file_dialog = Wx::FileDialog->new($frame, "Choose a file to open", $app->current_dir, '', 'Cedit files|*.ced|All files|*', wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        return unless $file_dialog->ShowModal == wxID_OK;
        $filename = $file_dialog->GetPath;
        $app->current_dir($file_dialog->GetDirectory);
    }

    return unless my $key = Wx::GetPasswordFromUser("Enter key", "Key Entry", "", $frame);
    $app->cipher( Crypt::CBC->new( -key => $key, -cipher => 'Blowfish') );

    $log->debug("open from $filename");
    my $file_text = read_file($filename);

    # the file text contains the checksum of the plaintext, so we can warn about incorrect keys.
    # Assume that all checksums will be the same length (until we do something silly like change the checksum method).
    my $checksum_length = length $app->saved_checksum;

    my $file_checksum = substr($file_text, 0, $checksum_length, '');

    # remove and unpack the yaml chunk
    my $yaml_length = unpack('S', substr($file_text, 0, 2, ''));
    my $yaml = substr($file_text, 0, $yaml_length, '');
    my $property = Load($yaml) ;

    # apply the properties
    $app->dialogue_line( $property->{dialogue_line} );
    $app->change_font_size(0, $property->{font_size});
    $frame->SetSize($property->{width}, $property->{height});
    $frame->Move([ $property->{left}, $property->{top} ]);

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

    # the RichText control will drop a single trailing linefeed, if one or more LFs end the string.
    # Stop this happening so we can compare file and edit checksums without displaying the content.
    if ($edit_text =~ /\n\z/) {
        $log->info("preemptively restore LF");
        $edit_text .= "\n";
    }

    $app->control->{text_txt}->SetValue( $edit_text );

    $app->refresh_dialogue_styles;

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

    unless (defined $line_nbr) {
        my $pos = $text_txt->GetInsertionPoint;
        (undef, $line_nbr) = $text_txt->PositionToXY($pos);
        $log->info("current pos = $pos, line $line_nbr");
    }

    my $length = $text_txt->GetLineLength($line_nbr);
    my $start = $text_txt->XYToPosition(0,$line_nbr);
    my $end = $text_txt->XYToPosition($length,$line_nbr);

    my $style;
    if (exists $self->dialogue_line->{ $line_nbr } ) {
        $log->info("clear style");
        $style = $self->default_style;
        delete $self->dialogue_line->{ $line_nbr };
    }
    else {
        $style = $self->dialogue_style;
        $self->dialogue_line->{ $line_nbr } = 1;
    }
    $text_txt->SetStyle($start, $end, $style);

    return;
}

################################################################################
sub shift_dialogue_styles { #{{{2
    my ($self, $increment) = @_;

    my $text_txt = $self->control->{text_txt};

    my $pos = $text_txt->GetInsertionPoint;
    (undef, my $current_line) = $text_txt->PositionToXY($pos);
    $log->info("shift_dialogue_styles: current_line $current_line, increment $increment");

    my @dialogue_lines = sort { $increment > 0 ? $b <=> $a : $a <=> $b } keys %{ $self->dialogue_line };

    for my $line_nbr (@dialogue_lines) {
        next unless $line_nbr >= $current_line;
        $log->info("shift dialogue style from $line_nbr to $line_nbr + $increment");
        $self->toggle_dialogue_style($line_nbr);
        $self->toggle_dialogue_style($line_nbr + $increment);
    }

    return;
}

################################################################################
# Note that this won't take off any styles, so it only works after a load or a font
# size change.
sub refresh_dialogue_styles { #{{{2
    my ($self) = @_;

    my $text_txt = $self->control->{text_txt};

    for my $line_nbr (keys %{ $self->dialogue_line }) {
        my $length = $text_txt->GetLineLength($line_nbr);
        my $start = $text_txt->XYToPosition(0,$line_nbr);
        my $end = $text_txt->XYToPosition($length,$line_nbr);
        $text_txt->SetStyle($start, $end, $self->dialogue_style);
    }

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

    my $number_lines = $text_txt->GetNumberOfLines;
    for my $line_nbr (0 .. $number_lines - 1) {
        my $line = $text_txt->GetLineText($line_nbr);
        $html .= $app->dialogue_line->{$line_nbr}
            ? $table_start . $line . $table_end . "\n"
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

#    if (wxTheClipboard->Open()) {
#        wxTheClipboard->SetData( Wx::TextDataObject->new($html) );
#        wxTheClipboard->Close();
#    }

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

unless(caller){

    # list of options
    my @options = qw(
        man
        usage
        debug
        file=s
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
