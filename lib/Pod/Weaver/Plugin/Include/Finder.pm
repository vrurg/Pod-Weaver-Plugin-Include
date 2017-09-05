#
package Pod::Weaver::Plugin::Include::Finder;

our $VERSION = 'v0.1.903';

our $VERSION = 'v0.1.901';

# ABSTRACT: Finds source Pods in .pod files or modules.

=head1 SYNOPSIS

    use Pod::Weaver::Plugin::Include::Finder;
    
    my $finder = Pod::Weaver::Plugin::Include::Finder->new;
    my $template = $finder->get_template(
        template => 'tmplName',
        source => 'source.pod',
    );
    
=head1 DESCRIPTION

This module loads sources, parses them and caches templates found.

=cut

use Pod::Find qw<pod_where>;
use File::Find::Rule;
use Pod::Elemental;
use Pod::Elemental::Transformer::Pod5;

use Moose;
use namespace::autoclean;

=attr B<cache>

Cache of templates by sources. Hash of hashes where first level keys are
sources by their full file names; and second level keys are template names.
Each cache entry is an array of Pod nodes.

=cut

has cache => (
    is      => 'rw',
    isa     => 'HashRef[HashRef]',
    builder => 'init_cache',
);

=attr B<maps>

Mapping of short names into full path names. Short names are either aliases
or what is used with a C<=include> command. For example:

    =srcAlias alias Some::Module
    =include template@templates/src.pod

With these commands the map will contain keys I<alias> and I<templates/src.pod>.    

=cut

has maps => (
    is      => 'rw',
    isa     => 'HashRef[Str]',
    lazy    => 1,
    builder => 'init_maps',
);

=attr callerPlugin

Back reference to a L<Pod::Weaver::Plugin::Include> instance.

=cut

has callerPlugin => (
    is  => 'ro',
    isa => 'Pod::Weaver::Plugin::Include',
);

=attr pod_path

List of entries from C<pod_path> configuration variable.

=cut

has pod_path => (
    is      => 'rw',
    lazy    => 1,
    isa     => 'ArrayRef[Str]',
    builder => 'init_pod_path',
);

has logger => (
    is      => 'rw',
    lazy    => 1,
    builder => 'init_logger',
    handles => [qw<log log_debug log_fatal>],
);

=privAttr B<_tmplSource, _tmplName, _tmplContent>

Solely for use by C<load_file()> and C<_store_template()> methods.

=cut

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

=method B<find_source( $source )>

Takes a short source name (not alias!) and returns full path name for it or
I<undef> if not found.

Successful search is stored into C<maps> attribute.

=cut

sub find_source {
    my $this = shift;
    my ($source) = @_;

    my $podFile = pod_where( { -dirs => $this->pod_path }, $source );

    return undef unless defined $podFile;

    $this->maps->{$source} = $podFile;

    return $podFile;
}

=method B<register_alias( $alias, $source )>

Finds out the full path name for C<$source> and stores a new entry for C<$alias>
in C<maps> attribute. Does nothing if source is not found.

B<NOTE:> This method will result in two C<maps> entries: one for the C<$source>
and one for the C<$alias>.

Returns full path name of the C<$source>.

=cut

sub register_alias {
    my $this = shift;
    my ( $alias, $source ) = @_;

    my $podFile = $this->find_source($source);

    if ( defined $podFile ) {
        $this->maps->{$alias} = $podFile;
    }

    return $podFile;
}

=privMethod _store_template

Records a new template into the C<cache>.

=cut

sub _store_template {
    my $this = shift;

    return unless defined $this->_tmplName;
    
    $this->log_debug("Caching template", $this->_tmplName);

    $this->cache->{ $this->_tmplSource }{ $this->_tmplName } =
      $this->_tmplContent;

    $this->_clear_tmplName;
    $this->_clear_tmplContent;
}

sub _add2tmpl {
    my $this = shift;
    my $para = shift;
    
    if ($this->_tmplName) {
        push @{$this->_tmplContent}, $para;
    }
}

=method B<parse_tmpl( $str )>

Parses argument of C<=tmpl> command. Returns a profile hash with two keys:

=over 4

=item C<hidden>

Boolean, I<true> if template is declared hidden.

=item C<name>

Template name.

=back

=cut

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
## Please see file perltidy.ERR
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

=method C<load_file( $file )>

Loads and parses a source file defined by C<$file>. The result is stored into
C<cache>.

Returns I<true> if file has been successully read by L<Pod::Elemental>.

=cut

sub load_file {
    my $this = shift;
    my ( $file, %opts ) = @_;

    $this->log_debug( "Loading file " . $file );

    my $showContent = 0;

    my $doc = Pod::Elemental->read_file($file);
    if ($doc) {
        Pod::Elemental::Transformer::Pod5->new->transform_node($doc);

        $this->_tmplSource($file);

        my $children = $doc->children;
      ELEM: for ( my $i = 0 ; $i < @$children ; $i++ ) {
            my $para = $children->[$i];
            if ( $para->isa('Pod::Elemental::Element::Pod5::Command') ) {
                if ( $para->command eq 'tmpl' ) {
                    $this->log_debug("Closing template by =tmpl");
                    $this->_store_template;

                    my $attrs = $this->parse_tmpl( $para->content );
                    $showContent = $attrs->{name} eq 'test' if $attrs->{name};
                    $this->_tmplName( $attrs->{name} ) if $attrs->{name};
                }
                else {
                    $this->_add2tmpl($para);
                }
                next ELEM;
            }
            elsif ( defined $this->_tmplName ) {
                $this->_add2tmpl($para);
            }
        }

        # If any template was declared at the document end.
        $this->log_debug("Closing any remaining template");
        $this->_store_template;
        $this->_clear_tmplSource;
    }
    else {
        die "Failed to load doc from $file";
    }

    return defined $doc;
}

=method C<get_template( %opts )>

Returns a cached template. C<%opts> profile can have two keys:

=over 4

=item C<template>

Template name

=item C<source>

Source in short form including aliases.

=back

If a template is missing in the C<cache> then tries to C<load_file()>.

Returns I<undef> if failed.

=cut

sub get_template {
    my $this = shift;
    my %opts = @_;

    my $fullName = $this->maps->{ $opts{source} };

    my $template;

    unless ( defined $fullName ) {

        # Find file if specified by short name or module name.
        $fullName = $this->find_source( $opts{source} );
    }

    $this->log( "Cannot find source file for [" . $opts{source} . "]" )
      unless defined $fullName;

    return undef unless defined $fullName;

    $this->log_debug(
        "Found file $fullName for source [" . $opts{source} . "]" );

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

sub init_logger {
    my $this = shift;

    my $logger;

    if ( defined $this->callerPlugin ) {
        $logger = $this->callerPlugin->logger;
    }
    else {
        require Log::Dispatchouli;
        $logger = Log::Dispatchouli->new(
            {
                ident     => '-Include::Finder',
                to_stdout => 1,
                log_pid   => 0,
                debug     => 1,
            }
        );
    }
    return $logger;
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
