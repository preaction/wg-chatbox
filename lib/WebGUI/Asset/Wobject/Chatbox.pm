package WebGUI::Asset::Wobject::Chatbox;

$VERSION = "1.1.0";

#-------------------------------------------------------------------
# WebGUI is Copyright 2001-2009 Plain Black Corporation.
#-------------------------------------------------------------------
# Please read the legal notices (docs/legal.txt) and the license
# (docs/license.txt) that came with this distribution before using
# this software.
#-------------------------------------------------------------------
# http://www.plainblack.com                     info@plainblack.com
#-------------------------------------------------------------------

=head1 NAME

WebGUI::Asset::Wobject::Chatbox - Real-time chat on your website

=head1 DESCRIPTION 

TODO

=head1 METHODS

=cut

use strict;
use Tie::IxHash;
use WebGUI::International;
use WebGUI::Utility;
use Encode qw(decode_utf8 decode encode_utf8);
use utf8;
use JSON;

use base 'WebGUI::AssetAspect::Installable', 'WebGUI::Asset::Wobject';

#-------------------------------------------------------------------

=head2 definition ( )

=cut

sub definition {
    my $class       = shift;
    my $session     = shift;
    my $definition  = shift;

    my $i18n = WebGUI::International->new($session, "Asset_Chatbox");
    
    tie my %properties, 'Tie::IxHash', (
        templateIdView  => {
            tab             => "display",
            fieldType       => "template",
            namespace       => "Chatbox",
            label           => "View Template",
            hoverHelp       => "Template for normal view.",
        },
        templateIdChat  => {
            tab             => "display",
            fieldType       => "template",
            namespace       => "Chatbox/Chat",
            label           => "Chat Template",
            hoverHelp       => "Template for chat content.",
        },
        sortOrder       => {
            tab             => 'display',
            fieldType       => "selectBox",
            defaultValue    => 'desc',
            options         => { 
                asc     => $i18n->get('ascending'),
                desc    => $i18n->get('descending') 
            },
            label           => $i18n->get('sort order'),
            hoverHelp       => $i18n->get('sort order description'),
        },
        maxNumMessages  => {
            tab             => "display",
            fieldType       => "integer",
            defaultValue    => "20",
            label           => "Max Number Displayed",
            hoverHelp       => "The maximum number of messages to be displayed.",
        },
        maxIntMessages  => {
            tab             => "display",
            fieldType       => "interval",
            defaultValue    => 3600,
            label           => "Max Interval Displayed",
            hoverHelp       => "The maximum interval of messages to be displayed.",
        },
    );
    
    push @{$definition}, {
        assetName           => 'Chatbox',
        icon                => 'newAsset.gif',
        autoGenerateForms   => 1,
        tableName           => 'Chatbox',
        className           => 'WebGUI::Asset::Wobject::Chatbox',
        properties          => \%properties,
    };
    
    return $class->SUPER::definition($session, $definition);
}

#-------------------------------------------------------------------

=head2 getTemplateVars ( )

Gets a hashref of template vars about this asset.

=cut

sub getTemplateVars {
    my $self        = shift;
    my $var         = $self->get;

    # Get a friendly URL
    $var->{ url         } = $self->getUrl;

    return $var;
}

#-------------------------------------------------------------------

=head2 install ( session )

Install this asset.

=cut

sub install {
    my $class   = shift;
    $class->next::method( @_ );
    my ( $session ) = @_;

    # Install collateral table
    $session->db->write(q{
        CREATE TABLE `Chatbox_chat` (
            `assetId` VARCHAR(22) BINARY NOT NULL,
            `timestamp` BIGINT(20),
            `userId` VARCHAR(22) BINARY NOT NULL,
            `from` VARCHAR(30),
            `bodyText` LONGTEXT,
            INDEX (assetId)
        )
    });

    return;
}

#-------------------------------------------------------------------

=head2 prepareView ( )

See WebGUI::Asset::prepareView() for details.

=cut

sub prepareView {
	my $self = shift;
	$self->SUPER::prepareView();
	my $template = WebGUI::Asset::Template->new($self->session, $self->get("templateIdView"));
	$template->prepare;
	$self->{_viewTemplate} = $template;
}

#-------------------------------------------------------------------

=head2 uninstall ( session )

Remove this asset from the site.

=cut

sub uninstall {
    my $class   = shift;
    $class->next::method( @_ );
    my ( $session ) = @_;

    $session->db->write("DROP TABLE `Chatbox_chat`");
    
    return;
}

#-------------------------------------------------------------------

=head2 view ( )

View the Chatbox asset. View the form. Add new chat messages if supplied
via optional URL parameters.

Optional URL Parameters:
    bodyText            - Post some text to the Chatbox
    from                - (Visitors only) say who you are
                        

=cut

sub view {
    my $self        = shift;
    my $session     = $self->session;	
    my $form        = $session->form;
    my $db          = $session->db;
    
    my $var         = $self->getTemplateVars;

    # If we have text to add, add it
    if ($form->get("bodyText")) {
        my $sql = q{
            INSERT INTO `Chatbox_chat` 
                (`assetId`, `userId`, `timestamp`, `bodyText`, `from`)
                VALUES (?, ?, ?, ?, ?)
        };

        my $placeholders = [
            $self->getId,                       # assetId
            $session->user->userId,             # userId
            $session->datetime->time,           # timestamp
            $form->get("bodyText"),             # bodyText
        ];

        # Set "from" column
        if ($session->user->isInGroup("2")) { # Registered users
            push @$placeholders, 
                $session->user->profileField("alias") || $session->user->username;
	    } 
        else { # Visitors
            push @$placeholders, $form->get("from") || "Anonymous";
        }

        $db->write($sql, $placeholders);
    }

    # Embed content generated by viewChat method
	$var->{ chat } = $self->www_chat;

    # Build a form to add data to the Chatbox
    $var->{ form_start }
        = WebGUI::Form::formHeader($session, { action => $self->getUrl });

    $var->{ form_from }
        = $session->user->isInGroup("2") 
        ? $session->user->profileField("alias") || $session->user->username
        : WebGUI::Form::text($session, { name => "from" });

    $var->{ form_bodyText }
        = WebGUI::Form::text($session, { name => "bodyText", size => "15" });

    $var->{ form_submit }
        = WebGUI::Form::submit($session, { name => "submit", value => "Senden" });

    $var->{ form_end }
        = WebGUI::Form::formFooter();
    
    return $self->processTemplate($var, undef, $self->{_viewTemplate});
	}


#-------------------------------------------------------------------

=head2 _chatTemplateVars ( )

Fills the template variables for the chat loop. This is a private sub used by 
www_chat and www_json. A hash reference is returned containing the loop stored
under 'chat'.

=cut

sub _chatTemplateVars {
	my $self        = shift;
	my $session     = $self->session;	
    my $db          = $session->db;
    
    my $var         = $self->getTemplateVars;

    # Show the data for this Chatbox
    $var->{ chat } = $db->buildArrayRefOfHashRefs(
        "SELECT * FROM Chatbox_chat WHERE (assetId=? AND timestamp>=?) ORDER BY timestamp DESC LIMIT ?", [
            $self->getId,                                               # asset Id
            $session->datetime->time - $self->get('maxIntMessages'),    # epoch time of earliest messages to be displayed
            $self->get('maxNumMessages'),                               # maximum number of messages to be displayed
        ]
    );
    # Check whether asceding order was requested.
    if ($self->get('sortOrder') eq 'asc') {
        # Resort messages in ascending order by comparison of timestamps. Note that we 
        # cannot do this in the SQL query since the combination of asceding order and
        # truncation of results by the limit statement would prevent display of most 
        # recent messages!
        @{$var->{ chat }} = sort { $a->{timestamp} <=> $b->{timestamp} } @{$var->{chat}}
    }

    # Iterate through array of messages
    foreach my $msg(@{$var->{ chat }}) {
        # Add formated date and time strings
        $msg->{ date } = $session->datetime->epochToHuman($msg->{ timestamp }, '%z');
        $msg->{ time } = $session->datetime->epochToHuman($msg->{ timestamp }, '%Z');

        # Consider only registered users
        if ($session->user->isInGroup("2")) {
            
            # Check if alias or username was mentioned
            my $name = $session->user->profileField("alias") || $session->user->username;            
            if ($msg->{bodyText} =~ m/$name/) {
                # Set highlight flag
                $msg->{highlight} = 1; 
                # Mark username for highlighting
                $msg->{bodyText} =~ s!$name!<span class="highlight">$&</span>!;
            }
	    } 
    }

    # Return reference to array of template vars
    return $var;
}

#-------------------------------------------------------------------

=head2 www_chat ( )

Renders the chat messages of the chatbox. The chatbox chat template is used
for processing. This sub is used by www_view and is further intended to be 
used directly by JS for auto-updating of chat messages. 

=cut


sub www_chat {
    my $self    = shift;
    my $session = $self->session;

    my $var = $self->_chatTemplateVars;

    my $template = WebGUI::Asset->new($self->session, $self->get("templateIdChat"),"WebGUI::Asset::Template");    
    return $template->process($var);
}

#-------------------------------------------------------------------

=head2 www_json

Returns the chat messages in JSON format for AJAX.

=cut

sub www_json {
    my $self    = shift;
    my $session = $self->session;

    my $var = $self->_chatTemplateVars;

    $session->http->setMimeType('application/json');
    return encode_json($var);
}

1;
