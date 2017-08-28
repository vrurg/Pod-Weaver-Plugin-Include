#
package Pod::Elemental::Transformer::Include::Finder;

# ABSTRACT: Finds source PODs in .pod files or modules.

use Pod::Find qw<pod_where>;
use File::Find::Rule;
use Pod::Elemental;
use Pod::Elemental::Transformer::Pod5;

use Moose;
use namespace::autoclean;

# Cached templates categorized by file names as the hash first level keys.
# $this->cache->{$fullFileName}{$templateName} -> $pod
has cache => (
    is      => 'rw',
    isa     => 'HashRef[HashRef]',
    builder => 'init_cache',
);

# Mapping of short names into full path names. Includes alises and module
# names.
has maps => (
    is      => 'rw',
    isa     => 'HashRef[Str]',
    lazy    => 1,
    builder => 'init_maps',
);

has callerPlugin => (
    is  => 'ro',
    isa => 'Pod::Weaver::Plugin::Include',
);

has pod_path => (
    is      => 'rw',
    lazy    => 1,
    isa     => 'ArrayRef[Str]',
    builder => 'init_pod_path',
);

has _tmplSource => (
    is      => 'rw',
    clearer => '_clear_tmplSource',
    isa     => 'Str',
);

has _tmplName => (
    is      => 'rw',
    clearer => '_clear_tmplName',
    isa     => 'Str',
);

has _tmplContent => (
    is      => 'rw',
    isa     => 'ArrayRef',
    clearer => '_clear_tmplContent',
    lazy    => 1,
    default => sub { [] },
);

sub find_source {
    my $this = shift;
    my ($source) = @_;

    my $podFile = pod_where( { -dirs => $this->pod_path }, $source );

    return undef unless defined $podFile;

    $this->maps->{$source} = $podFile;

    return $podFile;
}

sub register_alias {
    my $this = shift;
    my ( $alias, $source ) = @_;

    my $podFile = $this->find_source($source);

    if ( defined $podFile ) {
        $this->maps->{$alias} = $podFile;
    }

    return $podFile;
}

sub _store_template {
    my $this = shift;

    return unless defined $this->_tmplName;

    $this->cache->{ $this->_tmplSource }{ $this->_tmplName } =
      $this->_tmplContent;

    $this->_clear_tmplName;
    $this->_clear_tmplContent;
}

sub parse_tmpl {
    my $this = shift;
    my $str  = shift;

    my $attrs = {};

    if ($str) {
        $str =~ m/
                ^\s*
                (?<hidden>-)?
                (?<name>
                    [\p{XPosixAlpha}_]
                    ([\p{XPosixAlnum}_])*
                )
                \s*$
            /xn;

        if ( $+{name} ) {
            $attrs->{name}   = $+{name};
            $attrs->{hidden} = defined $+{hidden};
        }
        else {
            # $str is not empty but no valid name found.
            $attrs->{badName} = 1;
        }
    }

    return $attrs;
}

sub load_file {
    my $this = shift;
    my ( $file, %opts ) = @_;

    my $doc = Pod::Elemental->read_file($file);
    if ($doc) {
        Pod::Elemental::Transformer::Pod5->new->transform_node($doc);

        $this->_tmplSource($file);

        my $children = $doc->children;
      ELEM: for ( my $i = 0 ; $i < @$children ; $i++ ) {
            my $para = $children->[$i];
            if ( $para->isa('Pod::Elemental::Element::Pod5::Command') ) {
                if ( $para->command eq 'tmpl' ) {
                    $this->_store_template;

                    my $attrs = $this->parse_tmpl( $para->content );
                    $this->_tmplName( $attrs->{name} ) if $attrs->{name};
                }
                else {
                    push @{ $this->_tmplContent }, $para;
                }
                next ELEM;
            }
            elsif ( $para->isa('Pod::Elemental::Element::Pod5::Nonpod') ) {

                # If current pod segment ended – store template.
                $this->_store_template;
            }
            elsif ( defined $this->_tmplName ) {
                push @{ $this->_tmplContent }, $para;
            }
        }

        # If any template was declared at the document end.
        $this->_store_template;
        $this->_clear_tmplSource;
    }
    else {
        die "Failed to load doc from $file";
    }

    return defined $doc;
}

sub get_template {
    my $this = shift;
    my %opts = @_;

    my $fullName = $this->maps->{ $opts{source} };

    my $template;

    unless ( defined $fullName ) {

        # Find file if specified by short name or module name.
        $fullName = $this->find_source( $opts{source} );
    }

    return undef unless defined $fullName;

    unless ( $template = $this->cache->{$fullName}{ $opts{template} } ) {
        if ( my $doc = $this->load_file( $fullName, %opts ) ) {

            $template = $this->cache->{$fullName}{ $opts{template} };
        }
    }
    return $template;
}

sub init_cache {
    return {};
}

sub init_maps {
    return {};
}

sub init_pod_path {
    my $this = shift;

    return defined $this->callerPlugin
      ? $this->callerPlugin->pod_path
      : [qw<./lib>];
}

1;
