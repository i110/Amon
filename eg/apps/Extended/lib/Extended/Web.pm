package Extended::Web;
use strict;
use warnings;
use parent qw/Extended Amon2::Web/;

use Extended::Web::C::Root;

use Extended::Web::Request;
sub create_request  { Extended::Web::Request->new($_[1]) }

use Extended::Web::Dispatcher;
sub dispatch {
    my $ret = Extended::Web::Dispatcher->dispatch( $_[0] );
    $ret or die "response is not generated";
    $ret;
}

# setup view class
use Tiffany::Text::MicroTemplate::Extended;
{
    my $view_conf = __PACKAGE__->config->{'Text::MicroTemplate::Extended'};
    my $view      = Tiffany::Text::MicroTemplate::Extended->new($view_conf);
    sub create_view { $view }
}

__PACKAGE__->load_plugins(
    'Web::HTTPSession' => {
        state => 'Cookie',
        store => 'OnMemory',
    },
    'Web::MobileAgent'
);

1;
