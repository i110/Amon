use strict;
use warnings;
use Plack::Request;
use Test::More;

{
    package MyApp::Web::Dispatcher;
    use Amon::Web::Dispatcher::HTTPxDispatcher;
    connect 'blog/:year/:month' => { controller => 'Blog', action => 'show' };
}

{
    package MyApp::Web::C::Blog;
    sub show {
        my ($class, $args) = @_;
        [200, [], "YEAR: $args->{year}, MONTH: $args->{month}"];
    }
}

{
    package MyApp;
    use Amon -base;
}

my $c = MyApp->bootstrap(web_base => 'MyApp::Web');

my $req = Plack::Request->new({PATH_INFO => '/blog/2009/01'});
my $ret = MyApp::Web::Dispatcher->dispatch($req);
is $ret->[2], 'YEAR: 2009, MONTH: 01';

done_testing;