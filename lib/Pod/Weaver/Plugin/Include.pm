use strict;
use warnings;

package Pod::Weaver::Plugin::Include;

# ABSTRACT: Support for including sections of POD from other files

use version v0.77;

our $VERSION = v0.01;

use Moose;
use namespace::autoclean;
with qw<Pod::Weaver::Role::Dialect>;

has pod_path => (
    is => 'rw',
);

sub translate_dialect {
    my $this = shift;
    Pod::Elemental::Transformer::Include->new( callerPlugin => $this, )
      ->transformNode( $_[1], );
}

package Pod::Elemental::Transformer::Include {
    use Moose;
    with qw<Pod::Elemental::Transformer>;

    has callerPlugin => (
        is  => 'rw',
        isa => 'Pod::Weaver::Plugin::Include',
    );

    sub transform_node {
        my ( $this, $node ) = @_;
    }
}

1;
