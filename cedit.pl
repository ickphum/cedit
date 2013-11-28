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

use Wx qw[:everything];
use base qw(Wx::App Class::Accessor::Fast);
use Data::Dumper;
use File::Basename;
use File::Slurp qw(read_file write_file);
use Wx::XRC;
use Digest::SHA qw(sha1_hex);
use Crypt::CBC;

__PACKAGE__->mk_accessors( qw(frame xrc filename key saved_checksum control current_dir cipher) );

sub new { # {{{1
    my( $class, $option ) = @_;
    my $self = $class->SUPER::new();

    $self->xrc( Wx::XmlResource->new() );
    $self->xrc->InitAllHandlers;
    my $custom_xrc_handler = CeditXRCHandler->new ;
    $custom_xrc_handler->AddStyle('wxWANTS_CHARS', wxWANTS_CHARS);
    $self->xrc->AddHandler($custom_xrc_handler);

    $self->xrc->Load('main.xrc');

    $self->frame( $self->xrc->LoadFrame(undef, 'main'));

    Wx::Event::EVT_MENU($self->frame, wxID_NEW, \&new_file);
    Wx::Event::EVT_MENU($self->frame, wxID_OPEN, \&open_file);
    Wx::Event::EVT_MENU($self->frame, wxID_SAVE, \&save_file);
    Wx::Event::EVT_MENU($self->frame, wxID_ZOOM_IN, sub { $self->change_font_size(2); });
    Wx::Event::EVT_MENU($self->frame, wxID_ZOOM_OUT, sub { $self->change_font_size(-2); });
    Wx::Event::EVT_MENU($self->frame, wxID_HELP, sub { $self->apply_dialogue_style; });

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

    $self->SetTopWindow($self->frame);
    $self->frame->Show(1);

    $self->current_dir($option->{bin_dir});
    $self->saved_checksum( sha1_hex('') );

    if ($option->{file}) {
        open_file($self->frame, undef, $option->{file});
    }

    return $self;
}

################################################################################
# Just clear the text control and the filename and key attributes
sub new_file { #{{{2
    my ($frame, $event) = @_;

    my $app = wxTheApp;
    return unless $app->check_for_changes;

    $app->control->{text_rtc}->Clear;
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

    my $edit_text = $app->control->{text_rtc}->GetValue;
    my $checksum = sha1_hex($edit_text);
    $app->saved_checksum($checksum);

    # save the checksum so we can identify wrong keys
    my $file_text = $checksum . $app->cipher->encrypt($edit_text);

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

    return unless my $key = Wx::GetPasswordFromUser("Choose key", "Key Entry", "", $frame);
    $app->cipher( Crypt::CBC->new( -key => $key, -cipher => 'Blowfish') );

    $log->debug("open from $filename");
    my $file_text = read_file($filename);

    # the file text contains the checksum of the plaintext, so we can warn about incorrect keys.
    # Assume that all checksums will be the same length (until we do something silly like change the checksum method).
    my $checksum_length = length $app->saved_checksum;

    my $file_checksum = substr($file_text, 0, $checksum_length, '');

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

    $app->control->{text_rtc}->SetValue( $edit_text );

    # set once open is successful
    $app->saved_checksum($edit_checksum);
    $app->filename($filename);
    $app->key($key);

    return;
}

################################################################################
sub change_font_size { #{{{2
    my ($self, $increment) = @_;

    my $text_rtc = $self->control->{text_rtc};

    my $basic_style = $text_rtc->GetBasicStyle;
    my $font = $basic_style->GetFont;
    my $size = $font->GetPointSize;
    $font->SetPointSize($size + $increment);
    $text_rtc->SetFont($font);

    return;
}

################################################################################
sub apply_dialogue_style { #{{{2
    my ($self) = @_;

    my $text_rtc = $self->control->{text_rtc};

    my $pos = $text_rtc->GetCaretPosition;
    my ($column, $line) = $text_rtc->PositionToXY($pos);
    $log->info("current pos = $pos, at $line,$column");
    my $length = $text_rtc->GetLineLength($line);
    my $start = $text_rtc->XYToPosition(1,$line);
    my $end = $text_rtc->XYToPosition($length - 1,$line);

    my $style = Wx::TextAttr->new();
    $style->SetLeftIndent(10);
#    $style->SetFontStyle(wxTEXT_ATTR_FONT_ITALIC);
    $text_rtc->SetStyleEx($start, $end, $style);

    return;
}

################################################################################
sub check_for_changes { #{{{2
    my ($self) = @_;

    my $current_text = $self->control->{text_rtc}->GetValue;
    my $checksum = sha1_hex($current_text);

    $log->debug("check_for_changes; now $checksum, saved " . $self->saved_checksum);
    return $checksum eq $self->saved_checksum
        ? 1
        : wxYES == Wx::MessageBox("Ok to lose changes?", "Lose Changes", wxYES_NO, $self->frame);
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