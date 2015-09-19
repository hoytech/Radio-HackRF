package Radio::HackRF;

our $VERSION = '0.100';

require XSLoader;
XSLoader::load('Radio::HackRF', $VERSION);

use common::sense;
use AnyEvent;
use AnyEvent::Util;


sub new {
  my ($class, %args) = @_;

  my $self = {};
  bless $self, $class;

  $self->{ctx} = new_context();
  $self->{state} = 'IDLE';

  ($self->{perl_side_signalling_fh}, $self->{c_side_signalling_fh}) = AnyEvent::Util::portable_socketpair();

  die "couldn't create signalling socketpair: $!" if !$self->{perl_side_signalling_fh};

  _set_signalling_fd($self->{ctx}, fileno($self->{c_side_signalling_fh}));

  ## always turn off unless actually requested
  _set_amp_enable($self->{ctx}, $args{amp_enable} ? 1 : 0);

  if (!$args{dont_handle_sigint}) {
    $SIG{INT} = sub {
      $self->stop;
      exit;
    };
  }

  if (exists $args{freq}) {
    _set_freq($self->{ctx}, $args{freq});
  }

  if (exists $args{sample_rate}) {
    _set_sample_rate($self->{ctx}, $args{sample_rate});
  }

  return $self;
}

sub tx {
  my ($self, $cb) = @_;

  die "already in $self->{state} state" if $self->{state} ne 'IDLE';
  $self->{state} = 'TX';

  $self->{pipe_watcher} = AE::io $self->{perl_side_signalling_fh}, 0, sub {
    sysread $self->{perl_side_signalling_fh}, my $junk, 1; ## FIXME: non-blocking

    my $bytes_needed = _get_bytes_needed($self->{ctx});

    my $bytes = $cb->($bytes_needed);

    if (!defined $bytes) {
      $self->stop;
      return;
    }

    _copy_bytes($self->{ctx}, $$bytes);

    syswrite $self->{perl_side_signalling_fh}, "\x00";
  };

  _start_tx($self->{ctx});
}


sub stop {
  my ($self) = @_;

  if ($self->{state} eq 'TX') {
    $self->_stop_callback();
    _stop_tx($self->{ctx});
  }
}


sub _stop_callback {
  my ($self) = @_;

  _set_terminate_callback_flag($self->{ctx});

  $self->{state} = 'TERM';

  syswrite $self->{perl_side_signalling_fh}, "\x00";

  $self->{pipe_watcher} = AE::io $self->{perl_side_signalling_fh}, 0, sub {
    sysread $self->{perl_side_signalling_fh}, my $junk, 1; ## FIXME: non-blocking

    delete $self->{pipe_watcher};
    delete $self->{state};
  };
}



sub run {
  my ($self) = @_;

  $self->{cv} = AE::cv;

  $self->{cv}->recv;
}



1;



__END__

=encoding utf-8

=head1 NAME

Radio::HackRF - Control HackRF software defined radio

=head1 SYNOPSIS

    my $h = Radio::HackRF->new(
              freq => 35_000_000,
              sample_rate => 8_000_000,
            );

    $h->tx(sub {
        my $block_size = shift;

        my $output = "\x00" x $block_size;

        return \$output;
    });

    $h->run;

=head1 DESCRIPTION

=head1 SEE ALSO

L<Radio-HackRF github repo|https://github.com/hoytech/Radio-HackRF>

=head1 AUTHOR

Doug Hoyte, C<< <doug@hcsw.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2015 Doug Hoyte.

This module is licensed under the same terms as perl itself.
