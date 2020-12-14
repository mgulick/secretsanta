#!/usr/bin/env perl
# File: secretsanta.pl
# Abstract:
#   A script to randomly match secret santa participants, and send emails to
#   each participant telling them who they have been matched with.
#
# Copyright (c) 2020 Michael Gulick
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

use strict;
use warnings;

use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use File::Slurp qw(read_file);
use Getopt::Long;
use List::Util qw(shuffle);
use Pod::Usage;
use YAML;

Main();
exit 0;

# Subroutine: HGet =============================================================
# Abstract:
#   Get a hash value and assert that it exists.
#
sub HGet {
    my ($hptr, $key) = @_;

    if (! exists $hptr->{$key}) {
        die "assert - missing key '$key'\n";
    }
    return $hptr->{$key};
} # end sub HGet


# Subroutine: GetUsage =========================================================
# Abstract:
#   Read options from command line.
#
sub GetUsage {
    my $participantsFile = "participants.yml";
    my $emailConfFile = "emailconf.yml";
    my $dryRun;
    my $verbose;
    my $sendmail;
    my $help;
    my $man;
    GetOptions("participants|p=s" => \$participantsFile,
               "emailconf|m=s" => \$emailConfFile,
               "sendmail" => \$sendmail,
               "sendmail-dryrun" => \$dryRun,
               "verbose|v+" => \$verbose,
               "help|h" => sub { pod2usage(1) },
               "man" => sub { pod2usage(-verbose => 2) })
        or pod2usage(2);

    my $participantsYaml = read_file($participantsFile);
    my ($pplHPtr) = Load($participantsYaml);
    my $pplAPtr = $pplHPtr->{participants};

    if ($sendmail && $dryRun) {
        die "--sendmail and --sendmail-dryrun cannot be used together\n";
    }

    my $emailConfHPtr;
    if ($sendmail || $dryRun) {
        my $emailConfYaml = read_file($emailConfFile);
        ($emailConfHPtr) = Load($emailConfYaml);
    }

    return ($pplAPtr, $emailConfHPtr, $dryRun, $verbose);
} # end sub GetUsage


# Subroutine: MapParticipants ==================================================
# Abstract:
#   Take the participants list and generate an array of
#   { from => PERSON, to => PERSON}.
#   Each person looks like:
#     { name: NAME
#       email: EMAIL
#       address: ADDRESS
#       excludes: [ NAME, ... ] # optional
#     }
#
sub MapParticipants {
    my ($pplAPtr) = @_;

    my %nameMap = map { $_->{name} => $_ } @$pplAPtr;
    my %remaining = %nameMap;

    # Sort by number of excludes to maximize the chance of converging
    my @from =
        reverse
        sort { scalar @{$a->{excludes}} <=> scalar @{$b->{excludes}} }
        @$pplAPtr;
    my @pairs;

    for my $fromp (@from) {
        my %excludes = map { $_ => 1 } @{$fromp->{excludes}};
        $excludes{$fromp->{name}} = 1;
        my @choices = grep { !exists $excludes{$_->{name}} } values %remaining;
        if (@choices == 0) {
            die "assert - no choices left for $fromp->{name}!\n";
        }
        @choices = shuffle @choices;
        my $choice = $choices[0];
        push(@pairs, { from => $fromp, to => $choice });
        delete $remaining{$choice->{name}};
        #print "Matched $fromp->{name} to $choice->{name}\n";
    }

    return \@pairs;
} # end sub MapParticipants


# Subroutine: ConstructTransport ===============================================
# Abstract:
#   Construct the Email::Sender::Transport object used for sending email.  Uses
#   the 'smtpconf' fields specified in the email configuration yaml as arguments
#   passed directly to the Email::Sender::Transport::SMTP constructor.
#
sub ConstructTransport {
    my ($mailConfHPtr) = @_;

    my $transportOptsHPtr = $mailConfHPtr->{smtpconf};
    my $transport = Email::Sender::Transport::SMTP->new($transportOptsHPtr);

    return $transport;
} # end sub ConstructTransport


# Subroutine: ConstructMessage =================================================
# Abstract:
#   Construct the email message, an object of type Email::Simple, that will be
#   sent via Email::Sender::Simple.
#
#   Uses the 'from' and 'subject' fields from the 'msghdr' section in the email
#   configuration YAML file.  Substitute the '@FROM@', '@TO@', and
#   '@TO_ADDRESS@' fields into the message body template.
#
sub ConstructMessage {
    my ($hdrInfoHPtr, $bodyTmpl, $fromHPtr, $toHPtr) = @_;

    my $body = $bodyTmpl;
    $body =~ s{\@FROM\@}{$fromHPtr->{name}}g;
    $body =~ s{\@TO\@}{$toHPtr->{name}}g;
    $body =~ s{\@TO_ADDRESS\@}{$toHPtr->{address}}g;

    my $email = Email::Simple->create(
        header => [
            From => HGet($hdrInfoHPtr, 'from'),
            Subject => HGet($hdrInfoHPtr, 'subject'),
            To => $fromHPtr->{name} . " <" . $fromHPtr->{email} . ">",
        ],
        body => $body,
    );

    return $email;
} # end sub ConstructMessage


# Subroutine: Main =============================================================
# Abstract:
#   The main logic.  Checks usage, calls MapParticipants() to generate the
#   pairings, and then optionally sends an email to each participant.
#
sub Main {
    my ($pplAPtr, $emailConfHPtr, $dryRun, $verbose) = GetUsage();

    if ($dryRun) {
        $ENV{EMAIL_SENDER_TRANSPORT} = 'Test';
    }

    # Construct Pairs
    my $pairsAPtr;
    my $count = 0;
    my $success = 0;
    for (my $i = 0; $i < 1000; $i++) {
        $count++;
        eval {
            $pairsAPtr = MapParticipants($pplAPtr);
            $success = 1;
        };
        last if $success;
    }

    if (!$success) {
        die <<EOM;
Unable to successfully compute a complete set of matches in 1000 attempts.
Please try reducing the set of excludes.
EOM
    }

    if ($verbose) {
        print "Matches:\n";
        for my $pairHPtr (@$pairsAPtr) {
            print $pairHPtr->{from}->{name} . " => "
                . $pairHPtr->{to}->{name} . "\n";
        }
    }

    # Send E-Mail
    if ($emailConfHPtr) {
        my $transport = ConstructTransport($emailConfHPtr);
        my $hdrInfo = $emailConfHPtr->{msghdr};
        my $bodyTmpl = $emailConfHPtr->{msgbody};
        for my $pairHPtr (@$pairsAPtr) {
            my $fromHPtr = $pairHPtr->{from};
            my $toHPtr = $pairHPtr->{to};
            my $message = ConstructMessage($hdrInfo, $bodyTmpl, $fromHPtr,
                                           $toHPtr);
            print "(dryrun) " if $dryRun;
            print "Sending mail to '$fromHPtr->{name} <$fromHPtr->{email}>'\n";
            sendmail(
                $message,
                { transport => $transport },
            );
        }
    }

    if ($dryRun) {
        my @messages = Email::Sender::Simple->default_transport->deliveries;
        my $count = 0;
        for my $message (@messages) {
            $count++;
            print "Message $count:\n";
            print $message->{email}->as_string;
        }
    }
    return;
} # end sub Main

__END__

=pod

=head1 NAME

secretsanta.pl - Generate secret santa assignments

=head1 SYNOPSIS

secretsanta.pl [OPTION...]

 Options:
  -h, --help    Print this help message
      --man     Show the full man page
      --sendmail
                Send email to the participants
      --sendmail-dryrun
                Compose email but don't send it
  -p, --participants PARTICIPANTS_FILE
                Specify the filename containing participant info
  -m, --emailconf EMAILCONF_FILE
                Specify the filename containing email configuration
  -v, --verbose Be more verbose

=head1 DESCRIPTION

B<secretsanta.pl> reads a list of participants from a YAML file, matches them
randomly, and optionally sends an email to each participant informing them of
their match.

=head1 FILES

There are two primary input files: C<participants.yml> and C<emailconf.yml>.
These files can be overridden by the options B<--participants> and
B<--emailconf>, respectively.  The format of these files is documented here.

=head2 PARTICIPANTS_FILE

By default, a file named 'participants.yml' is used to find the list of
participants and their info (email address, mailing address, excludes).  A
different filename can be specified with the B<--participants> option.  The
format of this file is:

 ---
 participants:
   - name: First Last
     email: user@example.com
     address: |-
       NAME
       ADDRESS LINE 1
       ADDRESS LINE 2
     excludes:
       - Other Participant

The fields are as follows:

=over

=item C<name>

The name of the participant.

=item C<email>

The email address of the participant.  Use the format C<username@domain>.  When
email is sent, it will be address using both the name and the email address,
e.g. C<First Last <user@example.com>>.

=item C<address>

The address of the participant.  This is the address where their gift should be
mailed.

=item C<excludes>

This is a list of other participants that should not be assigned to this person.
This may be useful for preventing spouses from being matched with eachother.
The names provided in this list must match the C<name> field of other
participants.

If there are no excludes, the field can be written as:

 excludes: []

If there are excludes, the list should be a standard YAML list, e.g.:

 excludes:
   - FIRST
   - SECOND
   - ...

=back

=head2 EMAILCONF_FILE

By default, a file named 'emailconf.yml' is used to define the configuration of
the mail server used to send emails, as well as the C<From> C<Subject> and body
of the email.  The filename can be overridden with the B<--emailconf> option.

The format of this file is:

 ---
 msghdr:
   from: 'First Last <user@domain.com>'
   subject: 'This is the subject
 msgbody: |
  BODY LINE 1
  BODY LINE 2
  ...
 smtpconf:
   host: server
   ssl: 1
   port: 465
   sasl_username:
   sasl_password:

The fields are as follows:

=over

=item C<from>

The address used for the C<From> header when sending email.

=item C<subject>

The text used for the C<Subject> header when sending email.

=item C<msgbody>

The text used as the message body.  There are three keywords that will be
expanded.

=over

=item I<@FROM@>

The name of the participant that is being sent the email.  This is the person
that is responsible for sending the gift.

=item I<@TO@>

The name of the participant that the recipient is to send a gift to.

=item I<@TO_ADDRESS@>

The address for the person identified by I<@TO@>.  This is the address that the
gift should be sent to.

=back

=item C<smtpconf>

A collection of fields that are passed as key/value pairs to the
L<Email::Sender::Transport::SMTP(1)> constructor.  Some common fields are
documented here.

=over

=item C<host>

The hostname of the SMTP server.

=item C<ssl>

A value of '1' indicates that SSL/TLS should be used for communication.

=item C<port>

The port nubmer to use for the SMTP host.

=item C<sasl_username>

The username to be sent to the SMTP server for authentication.

=item C<sasl_password>

The password to be sent to the SMTP server for authentication.

=back

=back

=head1 OPTIONS

=over

=item B<-h, --help>

Print a brief help message and exit.

=item B<--man>

Print the manual page and exit.

=item B<--sendmail>

Send email using the specified mail configuration file (see B<--emailconf>).  This
option cannot be used with B<--sendmail-dryrun>.

=item B<--sendmail-dryrun>

Don't send emails, just print their contents to stdout.  This option cannot be
used with B<--sendmail>.

=item B<-p, --participants PARTICIPANTS_FILE>

Specify an alternative participants YAML file.  The default is
C<participants.yml>.  See I<PARTICIPANTS_FILE>.

=item B<-m, --emailconf EMAILCONF_FILE>

Specify an alternative email configuration YAML file.  The default is
C<emailconf.yml>.  See I<EMAILCONF_FILE>.

=item B<--verbose>

Be more verbose.  In particular, this will cause the application to print out
the pairings to the screen.

=back

=head1 EXAMPLES

Just generate pairings and print them to stdout.

 secretsanta.pl -v

Generate pairings and print email contents to stdout.

 secretsanta.pl --sendmail-dryrun

Generate pairings and send emails via SMTP.

 secretsanta.pl --sendmail

=head1 SEE ALSO

L<Email::Sender::Transport::SMTP(3)>

=cut

