package MediaWords::Util::ThriftExtractor;

use Modern::Perl "2013";
use MediaWords::CommonLibs;

# various helper functions for downloads

use strict;

use Carp;
use Scalar::Defer;
use Readonly;
use MediaWords::Thrift::Extractor;

sub extractor_version
{
    return 'readability-lxml-0.3.0.5';
}

sub get_extracted_html
{
    my ( $raw_html ) = @_;

    return '' unless ( $raw_html );

    die unless Encode::is_utf8( $raw_html );

    my $html_blocks = MediaWords::Thrift::Extractor::extract_html( $raw_html );

    my $ret = join( "\n\n", @$html_blocks );

    utf8::upgrade( $ret );

    die unless Encode::is_utf8( $ret );

    return $ret;
}

1;
