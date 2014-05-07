package Selenium::Remote::RemoteConnection;

#ABSTRACT: Connect to a selenium server

use Moo;
use Net::HTTP::Knork;
use Try::Tiny;
use LWP::UserAgent;
use HTTP::Headers;
use HTTP::Request;
use Carp qw(croak);
use JSON;
use Data::Dumper;
use Selenium::Remote::ErrorHandler;
use Test::File::ShareDir::Object::Dist;
use File::ShareDir ':ALL';


has 'remote_server_addr' => (
    is => 'rw',
);

has 'port' => (
    is => 'rw',
);


has 'testing' => (
    is      => 'rw',
    default => sub {0},
);

has 'debug' => (
    is      => 'rw',
    default => sub {0}
);

has 'ua' => (
    is      => 'lazy',
    builder => sub { return LWP::UserAgent->new; }
);

has 'rest_client' => (
    is      => 'lazy',
    builder => sub {
        my $self = shift;
        my $json_wire_spec;
        if ( $self->testing ) {
            my $obj =
              Test::File::ShareDir::Object::Dist->new(
                dists => { "Selenium-Remote-Driver" => "share/" } );
            $obj->install_all_dists;
            $obj->add_to_inc;
        }
        $json_wire_spec = dist_file(
            'Selenium-Remote-Driver',
            'config/json_wire_protocol.json'
        );
        my $rest_client = Net::HTTP::Knork->new(
            client   => $self->ua,
            base_url => "http://"
              . $self->remote_server_addr . ':'
              . $self->port,
            spec => $json_wire_spec
        );
        $rest_client->add_middleware(
            {   on_request => sub {
                    my $req = shift;
                    $req->header( 'Content-Type' => 'application/json' );
                    $req->header( 'Accept'       => 'application/json' );
                    $req->content( JSON->new->utf8(1)->allow_nonref->encode( $req->content ) );
                    my $base_url = $rest_client->base_url;
                    my $uri      = $req->uri;
                    my $path     = $uri->path;
                    unless ( $path =~ m/grid/ ) {
                        $req->uri( $base_url . '/wd/hub' . $path );
                    }

                    return $req;
                },
                on_response => sub {
                    my $resp = shift;
                    $resp->content(JSON->new->utf8(1)->allow_nonref->decode( $resp->content // {} ) );
                    return $resp;
                  }
            }
        );
        return $rest_client;
    }
);

sub BUILD {
    my $self = shift;
    my $status;
    try {
        $DB::single = 1;
        my $resp_status = $self->rest_client->status();
        $status = $self->_process_response($resp_status);
    }
    catch {
        croak "Could not connect to SeleniumWebDriver: $_";
    };
    if ( $status->{cmd_status} ne 'OK' ) {

        # Could be grid, see if we can talk to it
        my $resp_status = $self->rest_client->grid_status;
        $status = $self->_process_response($resp_status);
    }
    unless ( $status->{cmd_status} eq 'OK' ) {
        croak "Selenium server did not return proper status";
    }
}

sub _process_response {
    my ( $self, $response ) = @_;
    my $data;    # server response 'value' that'll be returned to the user
    print "RES: " . $response->content . "\n\n" if $self->debug;
    $data->{'sessionId'} = $response->content->{'sessionId'};

    if ( $response->is_error ) {
        my $error_handler = Selenium::Remote::ErrorHandler->new;
        $data->{'cmd_status'} = 'NOTOK';
        if ( defined $response->content ) {
            $data->{'cmd_return'} =
              $error_handler->process_error( $response->content );
        }
        else {
            $data->{'cmd_return'} =
              'Server returned error code ' . $response->code . ' and no data';
        }
        return $data;
    }
    elsif ( $response->is_success ) {
        $data->{'cmd_status'} = 'OK';
        if ( defined $response->content ) {
            $data->{'cmd_return'} = $response->content->{'value'};
        }
        else {
            $data->{'cmd_return'} =
                'Server returned status code '
              . $response->code
              . ' but no data';
        }
        return $data;
    }
    else {
        # No idea what the server is telling me, must be high
        $data->{'cmd_status'} = 'NOTOK';
        $data->{'cmd_return'} =
            'Server returned status code '
          . $response->code
          . ' which I don\'t understand';
        return $data;
    }
}


1;

__END__
