#!/usr/bin/perl

use strict;
use warnings;
use 5.010;

use lib 'lib';

use Carp;

use Future;
use IO::Async::Loop;

use Data::Dump qw( pp );
use File::Basename qw( basename );
use Getopt::Long;
use IO::Socket::SSL;
use List::Util qw( all );

use SyTest::Synapse;
use SyTest::HTTPClient;
use SyTest::MatrixClient;

GetOptions(
   'N|number=i'    => \(my $NUMBER = 2),
   'C|client-log+' => \my $CLIENT_LOG,
   'S|server-log+' => \my $SERVER_LOG,

   's|stop-on-fail+' => \my $STOP_ON_FAIL,
) or exit 1;

if( $CLIENT_LOG ) {
   require Net::Async::HTTP;
   require Class::Method::Modifiers;

   Class::Method::Modifiers::install_modifier( "Net::Async::HTTP",
      around => _do_request => sub {
         my ( $orig, $self, %args ) = @_;
         my $request = $args{request};

         my $request_uri = $request->uri;
         return $orig->( $self, %args ) if $request_uri->path =~ m{/events$};

         print STDERR "\e[1;32mRequesting\e[m:\n";
         print STDERR "  $_\n" for split m/\n/, $request->as_string;
         print STDERR "-- \n";

         return $orig->( $self, %args )
            ->on_done( sub {
               my ( $response ) = @_;

               print STDERR "\e[1;33mResponse\e[m from $request_uri:\n";
               print STDERR "  $_\n" for split m/\n/, $response->as_string;
               print STDERR "-- \n";
            }
         );
      }
   );

   Class::Method::Modifiers::install_modifier( "Net::Async::Matrix",
      before => _incoming_event => sub {
         my ( $self, $event ) = @_;

         print STDERR "\e[1;33mReceived event\e[m from $self->{server}:\n";
         print STDERR "  $_\n" for split m/\n/, pp( $event );
         print STDERR "-- \n";
      }
   );
}

my $loop = IO::Async::Loop->new;

# Start up 3 homeservers

my %synapses_by_port;
END {
   print STDERR "Killing synapse servers...\n" if %synapses_by_port;
   print STDERR "[${\$_->pid}] " and kill INT => $_->pid for values %synapses_by_port;
   print STDERR "\n";
}
$SIG{INT} = sub { exit 1 };

my @PORTS = 8001 .. 8000+$NUMBER;
my @f;
foreach my $port ( @PORTS ) {
   my $synapse = $synapses_by_port{$port} = SyTest::Synapse->new(
      synapse_dir  => "../synapse",
      port         => $port,
      print_output => $SERVER_LOG,
   );
   $loop->add( $synapse );

   push @f, Future->wait_any(
      $synapse->started_future,

      $loop->delay_future( after => 10 )
         ->then_fail( "Synapse server on port $port failed to start" ),
   );
}

Future->needs_all( @f )->get;

my @clients = Future->needs_all(
   map {
      my $port = $_;

      my $matrix = SyTest::MatrixClient->new(
         server => "localhost",
         port   => $port,
         SSL    => 1,
         SSL_verify_mode => SSL_VERIFY_NONE,

         on_error => sub {
            my ( $self, $failure, $name, @args ) = @_;

            die $failure unless $name and $name eq "http";
            my ( $response, $request ) = @args;

            print STDERR "Received from " . $request->uri . "\n";
            if( defined $response ) {
               print STDERR "  $_\n" for split m/\n/, $response->as_string;
            }
            else {
               print STDERR "No response\n";
            }

            die $failure;
         },
      );

      $loop->add( $matrix );

      Future->done( $matrix );
   } @PORTS
)->get;

# Some tests create objects as a side-effect that later tests will depend on,
# such as clients, users, rooms, etc... These are called the Environment
my %test_environment;

$test_environment{http_clients} = [ map {
   my $port = $_;
   my $client = SyTest::HTTPClient->new(
      uri_base => "https://localhost:$port/_matrix/client/api/v1",
   );
   $loop->add( $client );
   $client;
} @PORTS ];
$test_environment{first_http_client} = $test_environment{http_clients}->[0];

$test_environment{clients} = \@clients;

sub provide
{
   my ( $name, $value ) = @_;
   exists $test_environment{$name} and
      carp "Overwriting existing test environment key '$name'";

   $test_environment{$name} = $value;
}

my $failed;

sub test
{
   my ( $name, %params ) = @_;

   my @reqs;
   foreach my $req ( @{ $params{requires} || [] } ) {
      push @reqs, $test_environment{$req} and next if $test_environment{$req};

      print "  \e[1;33mSKIP\e[m $name due to lack of $req\n";
      return;
   }

   print "  \e[36mTesting if: $name\e[m... ";

   my $check = $params{check};

   my $success = eval {
      if( my $do = $params{do} ) {
         if( $check ) {
            eval { Future->wrap( $check->( @reqs ) )->get } and
               warn "Warning: $name was already passing before we did anything\n";
         }

         Future->wrap( $do->( @reqs ) )->get;
      }

      if( $check ) {
         my $attempts = $params{wait_time} // 0;
         do {
            eval {
               Future->wrap( $check->( @reqs ) )->get or
                  die "Test check function failed to return a true value"
            } and return 1; # returns from the containing outer eval

            die "$@" unless $attempts;

            $loop->delay_future( after => 1 )->get;
            $attempts--;
         } while(1);
      }

      1;
   };

   if( $success ) {
      print "\e[32mPASS\e[m\n";
   }
   else {
      my $e = $@; chomp $e;
      print "\e[1;31mFAIL\e[m:\n";
      print " | $_\n" for split m/\n/, $e;
      print " +----------------------\n";
      $failed++;
   }

   foreach my $req ( @{ $params{provides} || [] } ) {
      exists $test_environment{$req} and next;

      print "\e[1;31mWARN\e[m: Test failed to provide the '$req' environment as promised\n";
   }

   no warnings 'exiting';
   last TEST if $STOP_ON_FAIL and not $success;
}

sub prepare
{
   my ( $name, %params ) = @_;

   my @reqs;
   foreach my $req ( @{ $params{requires} || [] } ) {
      push @reqs, $test_environment{$req} and next if $test_environment{$req};

      print "  \e[1;33mSKIP\e[m '$name' prepararation due to lack of $req\n";
      return;
   }

   print "  \e[36mPreparing: $name\e[m... ";

   my $do = $params{do};
   my $success = eval {
      $do->( @reqs )->get;
      1;
   };

   if( $success ) {
      print "DONE\n";
   }
   else {
      my $e = $@; chomp $e;
      print "\e[1;31mFAIL\e[m:\n";
      print " | $_\n" for split m/\n/, $e;
      print " +----------------------\n";
      $failed++;
   }

    no warnings 'exiting';
    last TEST if $STOP_ON_FAIL and not $success;
}

## Some assertion functions useful by test scripts. Put them in their own
#    package so that croak will find the correct line number
package assertions {
   use Carp;
   use Scalar::Util qw( looks_like_number );

   sub json_object_ok
   {
      my ( $obj ) = @_;
      ref $obj eq "HASH" or croak "Expected a JSON object";
   }

   sub json_keys_ok
   {
      my ( $obj, @keys ) = @_;
      json_object_ok( $obj );
      foreach ( @keys ) {
         defined $obj->{$_} or croak "Expected a '$_' key";
      }
   }

   sub json_list_ok
   {
      my ( $list ) = @_;
      ref $list eq "ARRAY" or croak "Expected a JSON list";
   }

   sub json_number_ok
   {
      my ( $num ) = @_;
      !ref $num and looks_like_number( $num ) or croak "Expected a JSON number";
   }
}

{
   no strict 'refs';
   *$_ = \&{"assertions::$_"} for qw( json_object_ok json_keys_ok json_list_ok json_number_ok );
}

TEST: {
   walkdir(
      sub {
         my ( $filename ) = @_;

         return unless basename( $filename ) =~ m/^\d+.*\.pl$/;

         print "\e[1;36mRunning $filename...\e[m\n";

         # Slurp and eval() the file instead of do() because then lexical
         # environment such as strict/warnings will still apply
         my $code = do {
            open my $fh, "<", $filename or die "Cannot read $filename - $!\n";
            local $/; <$fh>
         };

         # Tell eval what the filename is so we get nicer warnings/errors that
         # give the filename instead of (eval 123)
         eval( "#line 1 $filename\n" . $code . "; 1" ) or die $@;
      },
      "tests"
   );
}

if( $failed ) {
   print STDERR "\n\e[1;31m$failed tests FAILED\e[m\n";
   exit 1;
}
else {
   print STDERR "\n\e[1;32mAll tests PASSED\e[m\n";
   exit 0;
}

# Can't use File::Find because of the fact it always sorts directories after
# nondirectories, even if you give a sort function
#   https://rt.perl.org/Public/Bug/Display.html?id=122968
sub walkdir
{
   my ( $code, $path ) = @_;

   my @ents = do {
      opendir my $dirh, $path or die "Cannot opendir $path - $!";
      readdir $dirh;
   };

   foreach my $ent ( sort grep { not m/^\./ } @ents ) {
      my $subpath = "$path/$ent";
      if ( -d $subpath ) {
         walkdir( $code, $subpath );
      }
      else {
         $code->( $subpath );
      }
   }
}