use strict;
use warnings;

package Pod::Weaver::Plugin::Include;

# ABSTRACT: Support for including sections of POD from other files

use version v0.77;

our $VERSION = v0.01;

use Moose;
use namespace::autoclean;
with qw<Pod::Weaver::Role::Dialect Pod::Weaver::Role::Preparer>;

has pod_path => (
    is      => 'rw',
    builder => 'init_pod_path',
);

has insert_errors => (
    is      => 'rw',
    builder => 'init_insert_errors',
);

has main_module => ( is => 'rw', );

has input => ( is => 'rw', );

around BUILDARGS => sub {
    my $orig   = shift;
    my $class  = shift;
    my ($args) = @_;

    if ( $args->{pod_path} && !ref( $args->{pod_path} ) ) {
        $args->{pod_path} = [ split /:/, $args->{pod_path} ];
    }

    return $orig->( $class, @_ );
};

sub prepare_input {
    my $this = shift;
    my ($input) = @_;

    $this->input($input);
}

sub translate_dialect {
    my $this = shift;
    my ($node) = @_;

    #say STDERR "pod_path=", $this->pod_path;
    #say STDERR "main_module=", $this->main_module;
    #say STDERR "zilla=", $this->input->{zilla};
    Pod::Elemental::Transformer::Include->new( callerPlugin => $this, )
      ->transform_node($node);
}

sub init_pod_path {
    return [qw<lib>];
}

sub init_insert_errors {
    return 0;
}

package Pod::Elemental::Transformer::Include {
    use Pod::Elemental::Transformer::Include::Finder;

    use Moose;
    use namespace::autoclean;
    with qw<Pod::Elemental::Transformer>;

    has callerPlugin => (
        is  => 'rw',
        isa => 'Pod::Weaver::Plugin::Include',
    );

    has logger => (
        is      => 'ro',
        lazy    => 1,
        builder => 'init_logger',
    );

    has finder => (
        is      => 'rw',
        lazy    => 1,
        isa     => 'Pod::Elemental::Transformer::Include::Finder',
        builder => 'init_finder',
    );

    has _children => (
        is      => 'rw',
        isa     => 'ArrayRef',
        lazy    => 1,
        clearer => '_clear_children',
        default => sub { [] },
    );

    has _skipContent => (
        is      => 'rw',
        isa     => 'Bool',
        default => 0,
    );

    sub _add_child {
        my $this = shift;

        return if $this->_skipContent;

        if ( ref( $_[0] ) eq 'ARRAY' ) {
            push @{ $this->_children }, @{ $_[0] };
        }
        else {
            push @{ $this->_children }, $_[0];
        }
    }

    sub _process_children {
        my $this = shift;
        my ( $children, %params ) = @_;

        my $curSrc = $params{source} || "main";
        my $included =
          $params{'.included'} || {};    # Hash of already included sources.
        my $logger = $this->callerPlugin->logger;

        $logger->log_debug( "Processing source "
              . $curSrc
              . " with "
              . scalar(@$children)
              . " children" )
          if defined $curSrc;
        
        for ( my $i = 0 ; $i < @$children ; $i++ ) {
            my $para = $children->[$i];
            
            if ( $para->isa('Pod::Elemental::Element::Pod5::Command') ) {
                $logger->log_debug( ( $curSrc ? "[$curSrc] " : "" )
                    . "Current command: "
                      . $para->command );
                if ( $para->command eq 'aliasInc' ) {
                    my ( $alias, $source ) = split ' ', $para->content, 2;
                    unless ( $this->finder->register_alias( $alias, $source ) )
                    {
                        $this->logger->log( "No source '", $source,
                            "' found for alias '",
                            $alias, "'\n" );
                    }
                }
                elsif ( $para->command eq 'include' ) {
                    my ( $name, $source ) = split /\@/, $para->content, 2;
                    $logger->log_debug("[$curSrc] Including $name from $source");

                    unless ( $included->{$source}{$name} ) {
                        $included->{$source}{$name} = $curSrc;
                        my $template = $this->finder->get_template(
                            template => $name,
                            source   => $source,
                        );
                        if ( defined $template ) {
                            $this->_process_children( $template,
                                source => $source, '.included' => $included, );
                        }
                        else {
                            $this->logger->log(
                                "No template '",
                                $name, "' found for '",
                                $source, "'\n"
                            );
                            $this->_add_child(
                                Pod::Elemental::Element::Pod5::Ordinary->new(
                                        content => "I<Can't load template '"
                                      . $name
                                      . "' from '"
                                      . $source
                                      . "'.>",
                                )
                            ) if $this->callerPlugin->insert_errors;
                        }
                    }
                    else {
                        $this->logger->log( "Circular load: "
                              . $name . "@"
                              . $source
                              . " has been loaded previously in "
                              . $included->{$source}{$name} );
                        $this->_add_child(
                            Pod::Elemental::Element::Pod5::Ordinary->new(
                                    content => "I<Circular load: "
                                  . $name . "@"
                                  . $source
                                  . " has been loaded previously in "
                                  . $included->{$source}{$name} . ">",
                            )
                        ) if $this->callerPlugin->insert_errors;
                    }
                }
                elsif ( $para->command eq 'tmpl' ) {
                    my $attrs = $this->finder->parse_tmpl( $para->content );

                    if ( $attrs->{badName} ) {
                        $this->logger->log(
                            "Bad tmpl definition '",
                            $para->content,
                            "': no valid name found"
                        );
                    }
                    elsif ( $attrs->{hidden} ) {
                        $this->_skipContent;
                    }
                }
                else {
                    # Any other kind of child
                    $this->_add_child($para);
                }
            }
            else {
                $this->_add_child($para);
            }
        }
    }

    sub transform_node {
        my ( $this, $node ) = @_;

        $this->_clear_children;

        $this->_process_children( $node->children );

        $node->children( $this->_children );

        return $node;
    }

    sub init_finder {
        my $this = shift;

        return Pod::Elemental::Transformer::Include::Finder->new(
            callerPlugin => $this->callerPlugin, );
    }

    sub init_logger {
        my $this = shift;
        return $this->callerPlugin->logger;
    }
}

1;
