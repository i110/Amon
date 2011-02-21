#!/usr/bin/perl
use strict;
use warnings;
use File::Path qw/mkpath/;
use Getopt::Long;
use Pod::Usage;
use Text::MicroTemplate ':all';

our $module;
our $dispatcher = 'RouterSimple';
GetOptions(
    'blueprint' => \my $blueprint,
    'dispatcher=s' => \$dispatcher,
    'skinny'       => \our $skinny,
    'help'         => \my $help,
) or pod2usage(0);
pod2usage(1) if $help;

my $confsrc = <<'END_OF_SRC';
-- lib/$path.pm
package <%= $module %>;
use strict;
use warnings;
use parent qw/Amon2/;
our $VERSION='0.01';
use 5.008001;

use Amon2::Config::Simple;
sub load_config { Amon2::Config::Simple->load(shift) }

use <%= $module %>::DBI;
sub dbh {
    my ($self) = @_;

    if (!defined $self->{dbh}) {
        my $conf = $self->config->{'DBI'} or die "missing configuration for 'DBI'";
        $self->{dbh} = <%= $module %>::DBI->connect(@$conf);
    }
    return $self->{dbh};
}

<% if ($skinny) { %>
use <%= $module %>::DB;

sub db {
    my ($self) = @_;
    if (!defined $self->{db}) {
        $self->{db} = <%= $module %>::DB->new(+{ dbh => $self->dbh });
    }
    return $self->{db};
}
<% } %>

1;
-- lib/$path/DBI.pm
use strict;
use warnings;

package <%= $module %>::DBI;
use parent qw/DBI/;

sub connect {
	my ($self, $dsn, $user, $pass, $attr) = @_;
    $attr->{RaiseError} = 0;
    if ($DBI::VERSION >= 1.614) {
        $attr->{AutoInactiveDestroy} = 1 unless exists $attr->{AutoInactiveDestroy};
    }
	if ($dsn =~ /^dbi:SQLite:/) {
		$attr->{sqlite_unicode} = 1 unless exists $attr->{sqlite_unicode};
	}
    if ($dsn =~ /^dbi:mysql:/) {
        $attr->{mysql_enable_utf8} = 1 unless exists $attr->{mysql_enable_utf8};
    }
	return $self->SUPER::connect($dsn, $user, $pass, $attr) or die "Cannot connect to server: $DBI::errstr";
}

package <%= $module %>::DBI::dr;
our @ISA = qw(DBI::dr);

package <%= $module %>::DBI::db;
our @ISA = qw(DBI::db);

use DBIx::TransactionManager;
use SQL::Interp ();

sub _txn_manager {
    my $self = shift;
    $self->{private_txn_manager} //= DBIx::TransactionManager->new($self);
}

sub txn_scope { $_[0]->_txn_manager->txn_scope(caller => [caller(0)]) }

sub do_i {
    my $self = shift;
    my ($sql, @bind) = SQL::Interp::sql_interp(@_);
    $self->do($sql, {}, @bind);
}

sub insert {
    my ($self, $table, $vars) = @_;
    $self->do_i("INSERT INTO $table", $vars);
}

sub prepare {
    my ($self, @args) = @_;
    my $sth = $self->SUPER::prepare(@args) or do {
        <%= $module %>::DBI::Util::handle_error($_[1], [], $self->errstr);
    };
    $sth->{private_sql} = $_[1];
    return $sth;
}

package <%= $module %>::DBI::st;
our @ISA = qw(DBI::st);

sub execute {
    my ($self, @args) = @_;
    $self->SUPER::execute(@args) or do {
        <%= $module %>::DBI::Util::handle_error($self->{private_sql}, \@args, $self->errstr);
    };
}

sub sql { $_[0]->{private_sql} }

package <%= $module %>::DBI::Util;
use Carp::Clan qw{^(DBI::|<%= $module %>::DBI::|DBD::)};
use Data::Dumper ();

sub handle_error {
    my ( $stmt, $bind, $reason ) = @_;

    $stmt =~ s/\n/\n          /gm;
    my $err = sprintf <<"TRACE", $reason, $stmt, Data::Dumper::Dumper($bind);

@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@ <%= $module %>::DBI 's Exception @@@@@
Reason  : %s
SQL     : %s
BIND    : %s
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
TRACE
    $err =~ s/\n\Z//;
    croak $err;
}

-- lib/$path/Web.pm
package <%= $module %>::Web;
use strict;
use warnings;
use parent qw/<%= $module %> Amon2::Web/;
use File::Spec;

# load all controller classes
use Module::Find ();
Module::Find::useall("<%= $module %>::Web::C");

# custom classes
use <%= $module %>::Web::Request;
use <%= $module %>::Web::Response;
sub create_request  { <%= $module %>::Web::Request->new($_[1]) }
sub create_response { shift; <%= $module %>::Web::Response->new(@_) }

# dispatcher
use <%= $module %>::Web::Dispatcher;
sub dispatch {
    return <%= $module %>::Web::Dispatcher->dispatch($_[0]) or die "response is not generated";
}

# setup view class
use Tiffany::Text::Xslate;
{
    my $view_conf = __PACKAGE__->config->{'Text::Xslate'} || die "missing configuration for Text::Xslate";
    unless (exists $view_conf->{path}) {
        $view_conf->{path} = [ File::Spec->catdir(__PACKAGE__->base_dir(), 'tmpl') ];
    }
    my $view = Tiffany::Text::Xslate->new(+{
        'syntax'   => 'TTerse',
        'module'   => [ 'Text::Xslate::Bridge::TT2Like' ],
        'function' => {
            c => sub { Amon2->context() },
            uri_with => sub { Amon2->context()->req->uri_with(@_) },
            uri_for  => sub { Amon2->context()->uri_for(@_) },
        },
        %$view_conf
    });
    sub create_view { $view }
}

# load plugins
use HTTP::Session::Store::File;
__PACKAGE__->load_plugins(
    'Web::FillInFormLite',
    'Web::NoCache', # do not cache the dynamic content by default
    'Web::CSRFDefender',
    'Web::HTTPSession' => {
        state => 'Cookie',
        store => HTTP::Session::Store::File->new(
            dir => File::Spec->tmpdir(),
        )
    },
);

# for your security
__PACKAGE__->add_trigger(
    AFTER_DISPATCH => sub {
        my ( $c, $res ) = @_;
        $res->header( 'X-Content-Type-Options' => 'nosniff' );
    },
);

__PACKAGE__->add_trigger(
    BEFORE_DISPATCH => sub {
        my ( $c ) = @_;
        # ...
        return;
    },
);

1;
-- lib/$path/Web/Dispatcher.pm
package <%= $module %>::Web::Dispatcher;
use strict;
use warnings;
<% if ($dispatcher eq 'RouterSimple') { %>
use Amon2::Web::Dispatcher::RouterSimple;

connect '/' => 'Root#index';
<% } else { %>
use Amon2::Web::Dispatcher::Lite;

any '/' => sub {
    my ($c) = @_;
    $c->render('index.tt');
};
<% } %>

1;
-- lib/$path/Web/Request.pm
package <%= $module %>::Web::Request;
use strict;
use parent qw/Amon2::Web::Request/;
1;
-- lib/$path/Web/Response.pm
package <%= $module %>::Web::Response;
use strict;
use parent qw/Amon2::Web::Response/;
1;
-- lib/$path/DB.pm skinny
package <%= $module %>::DB;
use DBIx::Skinny;
1;
-- lib/$path/Web/C/Root.pm RouterSimple
package <%= $module %>::Web::C::Root;
use strict;
use warnings;

sub index {
    my ($class, $c) = @_;
    $c->render("index.tt");
}

1;
-- config/development.pl
+{
    'DBI' => [
        'dbi:SQLite:dbname=development.db',
        '',
        '',
        +{
            sqlite_unicode => 1,
        }
    ],
    'Text::Xslate' => +{
    },
};
-- config/test.pl
+{
    'DBI' => [
        'dbi:SQLite:memory:',
        '',
        '',
        +{
            sqlite_unicode => 1,
        }
    ],
    'Text::Xslate' => +{
    },
};
-- lib/$path/ConfigLoader.pm
package <%= $module %>::ConfigLoader;
use strict;
use warnings;
use parent 'Amon2::ConfigLoader';
1;
-- script/make_schema.pl skinny
use strict;
use warnings;
use FindBin;
use File::Spec;
use lib File::Spec->catdir($FindBin::Bin, '..', 'lib');
use lib File::Spec->catdir($FindBin::Bin, '..', 'extlib', 'lib', 'perl5');
use <%= $module %>;
use FindBin;
use DBIx::Inspector 0.03;
use DBI;
use Text::Xslate;

my $c = <%= $module %>->bootstrap;
my $conf = $c->config->{'DBIx::Skinny'};

my $dbh = DBI->connect($conf->{dsn}, $conf->{username}, $conf->{password}, $conf->{connect_options}) or die "Cannot connect to DB: " . $DBI::errstr;
my $inspector = DBIx::Inspector->new(dbh => $dbh);
my $xslate = Text::Xslate->new(
    syntax => 'TTerse',
    module => ['Text::Xslate::Bridge::TT2Like'],
    type   => 'text',
);
my $tables = [
    map {
        +{
            name    => $_->name,
            pk      => join( ' ', map { $_->name } $_->primary_key ),
            columns => join( ' ', map { $_->name } $_->columns )
          }
      } $inspector->tables()
];
my $schema = $xslate->render_string(<<'...', {tables => $tables});
# XXX THIS FILE IS GENERATED BY script/make_schema.pl
package <%= $module %>::DB::Schema;
use strict;
use warnings;
use DBIx::Skinny::Schema;

[% FOR table IN tables %]
install_table '[% table.name %]' => sub {
%% IF table.pk
    pk      qw([% table.pk %]);
%% END
    columns qw([% table.columns %]);
};

[% END %]

1;
# XXX THIS FILE IS GENERATED BY script/make_schema.pl
...

my $dest = File::Spec->catfile($FindBin::Bin, '..', 'lib', '<%= $module %>', 'DB', 'Schema.pm');
open my $fh, '>', $dest or die "cannot open file '$dest': $!";
print {$fh} $schema;
close $fh;
-- sql/my.sql
-- sql/sqlite3.sql
-- tmpl/index.tt
[% INCLUDE 'include/header.tt' %]

hello, Amon2 world!

[% INCLUDE 'include/footer.tt' %]
-- tmpl/include/header.tt
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <meta http-equiv="content-type" content="text/html; charset=utf-8" />
    <title><%= $dist %></title>
    <meta http-equiv="Content-Style-Type" content="text/css" />  
    <meta http-equiv="Content-Script-Type" content="text/javascript" />  
    <% if ($blueprint) { %>
    <!-- Framework CSS -->
    <link rel="stylesheet" href="[% uri_for('/static/blueprint/screen.css') %]" type="text/css" media="screen, projection">
    <link rel="stylesheet" href="[% uri_for('/static/blueprint/print.css') %]" type="text/css" media="print">
    <!--[if lt IE 8]><link rel="stylesheet" href="[% uri_for('/static/blueprint/ie.css') %]" type="text/css" media="screen, projection"><![endif]-->
    <% } %>
    <link href="[% uri_for('/static/css/main.css') %]" rel="stylesheet" type="text/css" media="screen" />
</head>
<body>
    <div id="Container">
        <div id="Header">
            <a href="[% uri_for('/') %]"><%= $dist %></a>
        </div>
        <div id="Content">
-- tmpl/include/footer.tt
        </div>
        <div id="FooterContainer"><div id="Footer">
            Powered by Amon2
        </div></div>
    </div>
</body>
</html>
-- htdocs/static/css/main.css
/* reset.css */
html, body, div, span, object, iframe, h1, h2, h3, h4, h5, h6, p, blockquote, pre, a, abbr, acronym, address, code, del, dfn, em, img, q, dl, dt, dd, ol, ul, li, fieldset, form, label, legend, table, caption, tbody, tfoot, thead, tr, th, td {margin:0;padding:0;border:0;font-weight:inherit;font-style:inherit;font-size:100%;font-family:inherit;vertical-align:baseline;}
body {line-height:1.5;}
table {border-collapse:separate;border-spacing:0;}
caption, th, td {text-align:left;font-weight:normal;}
table, td, th {vertical-align:middle;}
blockquote:before, blockquote:after, q:before, q:after {content:"";}
blockquote, q {quotes:"" "";}
a img {border:none;}

/* main */
html,body {height:100%;}
body > #Container {height:auto;}

body {
    color: white;
    font-family: "メイリオ","Hiragino Kaku Gothic Pro","ヒラギノ角ゴ Pro W3","ＭＳ Ｐゴシック","Osaka",sans-selif;
    background-color: whitesmoke;
}

#Container {
    margin-left: 10px;
    margin-right: 10px;
    margin-bottom: 0px;
    margin-top: 0px;

    border-left: black solid 1px;
    border-right: black solid 1px;
    height: 100%;
    min-height:100%;
    background-color: white;
    color: black;
}

#Header {
    height: 50px;
    font-size: 36px;
    padding: 2px;
    text-align: center;
}

#Header a {
    color: black;
    font-weight: bold;
    text-decoration: none;
}

#Content {
    padding: 10px;
}

#FooterContainer {
    border-top: 1px solid black;
    font-size: 10px;
    color: black;
    position:absolute;
    bottom:0px;
    height:20px;
    width:100%;
}
#Footer {
    text-align: right;
    padding-right: 10px;
    padding-top: 2px;
}

-- $dist.psgi
use File::Spec;
use File::Basename;
use lib File::Spec->catdir(dirname(__FILE__), 'extlib', 'lib', 'perl5');
use lib File::Spec->catdir(dirname(__FILE__), 'lib');
use <%= $module %>::Web;
use Plack::Builder;

builder {
    enable 'Plack::Middleware::Static',
        path => qr{^(?:/static/|/robot\.txt$|/favicon.ico$)},
        root => File::Spec->catdir(dirname(__FILE__), 'htdocs');
    enable 'Plack::Middleware::ReverseProxy';
    <%= $module %>::Web->to_app();
};
-- Makefile.PL
use inc::Module::Install;
all_from "lib/<%= $path %>.pm";

license 'unknown';
author  'unknown';

tests 't/*.t t/*/*.t t/*/*/*.t';
requires 'Amon2';
requires 'Text::Xslate';
requires 'Text::Xslate::Bridge::TT2Like';
requires 'Plack::Middleware::ReverseProxy';
requires 'HTML::FillInForm::Lite';
requires 'Time::Piece';
<% if ($skinny) { %>
requires 'DBIx::Skinny';
requires 'DBIx::Inspector' => 0.03;
<% } %>
recursive_author_tests('xt');

WriteAll;
-- t/00_compile.t
use strict;
use warnings;
use Test::More;

use_ok $_ for qw(
    <%= $module %>
    <%= $module %>::DBI
    <%= $module %>::Web
    <%= $module %>::Web::Dispatcher
);

done_testing;
-- t/Util.pm
package t::Util;
BEGIN {
    unless ($ENV{PLACK_ENV}) {
        $ENV{PLACK_ENV} = 'test';
    }
}
use parent qw/Exporter/;
use Test::More 0.96;

{
    # utf8 hack.
    binmode Test::More->builder->$_, ":utf8" for qw/output failure_output todo_output/;                       
    no warnings 'redefine';
    my $code = \&Test::Builder::child;
    *Test::Builder::child = sub {
        my $builder = $code->(@_);
        binmode $builder->output,         ":utf8";
        binmode $builder->failure_output, ":utf8";
        binmode $builder->todo_output,    ":utf8";
        return $builder;
    };
}

1;
-- t/01_root.t
use strict;
use warnings;
use t::Util;
use Plack::Test;
use Plack::Util;
use Test::More;

my $app = Plack::Util::load_psgi '<%= $dist %>.psgi';
test_psgi
    app => $app,
    client => sub {
        my $cb = shift;
        my $req = HTTP::Request->new(GET => 'http://localhost/');
        my $res = $cb->($req);
        is $res->code, 200;
        diag $res->content if $res->code != 200;
    };

done_testing;
-- t/02_mech.t
use strict;
use warnings;
use t::Util;
use Plack::Test;
use Plack::Util;
use Test::More;
use Test::Requires 'Test::WWW::Mechanize::PSGI';

my $app = Plack::Util::load_psgi '<%= $dist %>.psgi';

my $mech = Test::WWW::Mechanize::PSGI->new(app => $app);
$mech->get_ok('/');

done_testing;
-- t/03_dbi.t
use strict;
use warnings;
use t::Util;
use Test::More;
use <%= $module %>::DBI;

eval {
    <%= $module %>::DBI->connect('dbi:unknown:', '', '');
};
ok $@, "dies with unknown driver, automatically.";

my $dbh = <%= $module %>::DBI->connect('dbi:SQLite::memory:', '', '');
$dbh->do(q{CREATE TABLE foo (e)});
$dbh->insert('foo', {e => 3});
$dbh->do_i('INSERT INTO foo ', {e => 4});
is join(',', map { @$_ } @{$dbh->selectall_arrayref('SELECT * FROM foo ORDER BY e')}), '3,4';

subtest 'utf8' => sub {
    $dbh->do(q{CREATE TABLE bar (x)});
    $dbh->insert(bar => { x => "こんにちは" });
    my ($x) = $dbh->selectrow_array(q{SELECT x FROM bar});
    is $x, "こんにちは";
};

eval {
    $dbh->insert('bar', {e => 3});
}; note $@;
ok $@, "Dies with unknown table name automatically.";
like $@, qr/<%= $module %>::DBI 's Exception/;

done_testing;
-- xt/01_podspell.t
use Test::More;
eval q{ use Test::Spelling };
plan skip_all => "Test::Spelling is not installed." if $@;
add_stopwords(map { split /[\s\:\-]/ } <DATA>);
$ENV{LANG} = 'C';
all_pod_files_spelling_ok('lib');
__DATA__
<%= $module %>
Tokuhiro Matsuno
Test::TCP
tokuhirom
AAJKLFJEF
GMAIL
COM
Tatsuhiko
Miyagawa
Kazuhiro
Osawa
lestrrat
typester
cho45
charsbar
coji
clouder
gunyarakun
hio_d
hirose31
ikebe
kan
kazeburo
daisuke
maki
TODO
kazuhooku
FAQ
Amon2
DBI
PSGI
URL
XS
env
.pm
-- xt/02_perlcritic.t
use strict;
use Test::More;
eval q{ use Test::Perl::Critic -profile => 'xt/perlcriticrc' };
plan skip_all => "Test::Perl::Critic is not installed." if $@;
all_critic_ok('lib');
-- xt/03_pod.t
use Test::More;
eval "use Test::Pod 1.00";
plan skip_all => "Test::Pod 1.00 required for testing POD" if $@;
all_pod_files_ok();
-- xt/perlcriticrc
[TestingAndDebugging::ProhibitNoStrict]
allow=refs
[-Subroutines::ProhibitSubroutinePrototypes]
[TestingAndDebugging::RequireUseStrict]
equivalent_modules = Mouse Mouse::Role Moose Amon2 Amon2::Web Amon2::Web::C Amon2::V::MT::Context Amon2::Web::Dispatcher Amon2::V::MT Amon2::Config DBIx::Skinny DBIx::Skinny::Schema Amon2::Web::Dispatcher::HTTPxDispatcher Any::Moose Amon2::Web::Dispatcher::RouterSimple DBIx::Skinny DBIx::Skinny::Schema Amon2::Web::Dispatcher::Lite common::sense
[-Subroutines::ProhibitExplicitReturnUndef]
-- .gitignore
Makefile
inc/
MANIFEST
*.bak
*.old
nytprof.out
development.db
-- htdocs/static/blueprint/ie.css blueprint
/* -----------------------------------------------------------------------


 Blueprint CSS Framework 1.0
 http://blueprintcss.org

   * Copyright (c) 2007-Present. See LICENSE for more info.
   * See README for instructions on how to use Blueprint.
   * For credits and origins, see AUTHORS.
   * This is a compressed file. See the sources in the 'src' directory.

----------------------------------------------------------------------- */

/* ie.css */
body {text-align:center;}
.container {text-align:left;}
* html .column, * html .span-1, * html .span-2, * html .span-3, * html .span-4, * html .span-5, * html .span-6, * html .span-7, * html .span-8, * html .span-9, * html .span-10, * html .span-11, * html .span-12, * html .span-13, * html .span-14, * html .span-15, * html .span-16, * html .span-17, * html .span-18, * html .span-19, * html .span-20, * html .span-21, * html .span-22, * html .span-23, * html .span-24 {display:inline;overflow-x:hidden;}
* html legend {margin:0px -8px 16px 0;padding:0;}
sup {vertical-align:text-top;}
sub {vertical-align:text-bottom;}
html>body p code {*white-space:normal;}
hr {margin:-8px auto 11px;}
img {-ms-interpolation-mode:bicubic;}
.clearfix, .container {display:inline-block;}
* html .clearfix, * html .container {height:1%;}
fieldset {padding-top:0;}
legend {margin-top:-0.2em;margin-bottom:1em;margin-left:-0.5em;}
textarea {overflow:auto;}
label {vertical-align:middle;position:relative;top:-0.25em;}
input.text, input.title, textarea {background-color:#fff;border:1px solid #bbb;}
input.text:focus, input.title:focus {border-color:#666;}
input.text, input.title, textarea, select {margin:0.5em 0;}
input.checkbox, input.radio {position:relative;top:.25em;}
form.inline div, form.inline p {vertical-align:middle;}
form.inline input.checkbox, form.inline input.radio, form.inline input.button, form.inline button {margin:0.5em 0;}
button, input.button {position:relative;top:0.25em;}
-- htdocs/static/blueprint/print.css blueprint
/* -----------------------------------------------------------------------


 Blueprint CSS Framework 1.0
 http://blueprintcss.org

   * Copyright (c) 2007-Present. See LICENSE for more info.
   * See README for instructions on how to use Blueprint.
   * For credits and origins, see AUTHORS.
   * This is a compressed file. See the sources in the 'src' directory.

----------------------------------------------------------------------- */

/* print.css */
body {line-height:1.5;font-family:"Helvetica Neue", Arial, Helvetica, sans-serif;color:#000;background:none;font-size:10pt;}
.container {background:none;}
hr {background:#ccc;color:#ccc;width:100%;height:2px;margin:2em 0;padding:0;border:none;}
hr.space {background:#fff;color:#fff;visibility:hidden;}
h1, h2, h3, h4, h5, h6 {font-family:"Helvetica Neue", Arial, "Lucida Grande", sans-serif;}
code {font:.9em "Courier New", Monaco, Courier, monospace;}
a img {border:none;}
p img.top {margin-top:0;}
blockquote {margin:1.5em;padding:1em;font-style:italic;font-size:.9em;}
.small {font-size:.9em;}
.large {font-size:1.1em;}
.quiet {color:#999;}
.hide {display:none;}
a:link, a:visited {background:transparent;font-weight:700;text-decoration:underline;}
a:link:after, a:visited:after {content:" (" attr(href) ")";font-size:90%;}
-- htdocs/static/blueprint/screen.css blueprint
/* -----------------------------------------------------------------------


 Blueprint CSS Framework 1.0
 http://blueprintcss.org

   * Copyright (c) 2007-Present. See LICENSE for more info.
   * See README for instructions on how to use Blueprint.
   * For credits and origins, see AUTHORS.
   * This is a compressed file. See the sources in the 'src' directory.

----------------------------------------------------------------------- */

/* reset.css */
html {margin:0;padding:0;border:0;}
body, div, span, object, iframe, h1, h2, h3, h4, h5, h6, p, blockquote, pre, a, abbr, acronym, address, code, del, dfn, em, img, q, dl, dt, dd, ol, ul, li, fieldset, form, label, legend, table, caption, tbody, tfoot, thead, tr, th, td, article, aside, dialog, figure, footer, header, hgroup, nav, section {margin:0;padding:0;border:0;font-weight:inherit;font-style:inherit;font-size:100%;font-family:inherit;vertical-align:baseline;}
article, aside, dialog, figure, footer, header, hgroup, nav, section {display:block;}
body {line-height:1.5;background:white;}
table {border-collapse:separate;border-spacing:0;}
caption, th, td {text-align:left;font-weight:normal;float:none !important;}
table, th, td {vertical-align:middle;}
blockquote:before, blockquote:after, q:before, q:after {content:'';}
blockquote, q {quotes:"" "";}
a img {border:none;}
:focus {outline:0;}

/* typography.css */
html {font-size:100.01%;}
body {font-size:75%;color:#222;background:#fff;font-family:"Helvetica Neue", Arial, Helvetica, sans-serif;}
h1, h2, h3, h4, h5, h6 {font-weight:normal;color:#111;}
h1 {font-size:3em;line-height:1;margin-bottom:0.5em;}
h2 {font-size:2em;margin-bottom:0.75em;}
h3 {font-size:1.5em;line-height:1;margin-bottom:1em;}
h4 {font-size:1.2em;line-height:1.25;margin-bottom:1.25em;}
h5 {font-size:1em;font-weight:bold;margin-bottom:1.5em;}
h6 {font-size:1em;font-weight:bold;}
h1 img, h2 img, h3 img, h4 img, h5 img, h6 img {margin:0;}
p {margin:0 0 1.5em;}
.left {float:left !important;}
p .left {margin:1.5em 1.5em 1.5em 0;padding:0;}
.right {float:right !important;}
p .right {margin:1.5em 0 1.5em 1.5em;padding:0;}
a:focus, a:hover {color:#09f;}
a {color:#06c;text-decoration:underline;}
blockquote {margin:1.5em;color:#666;font-style:italic;}
strong, dfn {font-weight:bold;}
em, dfn {font-style:italic;}
sup, sub {line-height:0;}
abbr, acronym {border-bottom:1px dotted #666;}
address {margin:0 0 1.5em;font-style:italic;}
del {color:#666;}
pre {margin:1.5em 0;white-space:pre;}
pre, code, tt {font:1em 'andale mono', 'lucida console', monospace;line-height:1.5;}
li ul, li ol {margin:0;}
ul, ol {margin:0 1.5em 1.5em 0;padding-left:1.5em;}
ul {list-style-type:disc;}
ol {list-style-type:decimal;}
dl {margin:0 0 1.5em 0;}
dl dt {font-weight:bold;}
dd {margin-left:1.5em;}
table {margin-bottom:1.4em;width:100%;}
th {font-weight:bold;}
thead th {background:#c3d9ff;}
th, td, caption {padding:4px 10px 4px 5px;}
tbody tr:nth-child(even) td, tbody tr.even td {background:#e5ecf9;}
tfoot {font-style:italic;}
caption {background:#eee;}
.small {font-size:.8em;margin-bottom:1.875em;line-height:1.875em;}
.large {font-size:1.2em;line-height:2.5em;margin-bottom:1.25em;}
.hide {display:none;}
.quiet {color:#666;}
.loud {color:#000;}
.highlight {background:#ff0;}
.added {background:#060;color:#fff;}
.removed {background:#900;color:#fff;}
.first {margin-left:0;padding-left:0;}
.last {margin-right:0;padding-right:0;}
.top {margin-top:0;padding-top:0;}
.bottom {margin-bottom:0;padding-bottom:0;}

/* forms.css */
label {font-weight:bold;}
fieldset {padding:0 1.4em 1.4em 1.4em;margin:0 0 1.5em 0;border:1px solid #ccc;}
legend {font-weight:bold;font-size:1.2em;margin-top:-0.2em;margin-bottom:1em;}
fieldset, #IE8#HACK {padding-top:1.4em;}
legend, #IE8#HACK {margin-top:0;margin-bottom:0;}
input[type=text], input[type=password], input.text, input.title, textarea {background-color:#fff;border:1px solid #bbb;}
input[type=text]:focus, input[type=password]:focus, input.text:focus, input.title:focus, textarea:focus {border-color:#666;}
select {background-color:#fff;border-width:1px;border-style:solid;}
input[type=text], input[type=password], input.text, input.title, textarea, select {margin:0.5em 0;}
input.text, input.title {width:300px;padding:5px;}
input.title {font-size:1.5em;}
textarea {width:390px;height:250px;padding:5px;}
form.inline {line-height:3;}
form.inline p {margin-bottom:0;}
.error, .alert, .notice, .success, .info {padding:0.8em;margin-bottom:1em;border:2px solid #ddd;}
.error, .alert {background:#fbe3e4;color:#8a1f11;border-color:#fbc2c4;}
.notice {background:#fff6bf;color:#514721;border-color:#ffd324;}
.success {background:#e6efc2;color:#264409;border-color:#c6d880;}
.info {background:#d5edf8;color:#205791;border-color:#92cae4;}
.error a, .alert a {color:#8a1f11;}
.notice a {color:#514721;}
.success a {color:#264409;}
.info a {color:#205791;}

/* grid.css */
.container {width:950px;margin:0 auto;}
.showgrid {background:url(src/grid.png);}
.column, .span-1, .span-2, .span-3, .span-4, .span-5, .span-6, .span-7, .span-8, .span-9, .span-10, .span-11, .span-12, .span-13, .span-14, .span-15, .span-16, .span-17, .span-18, .span-19, .span-20, .span-21, .span-22, .span-23, .span-24 {float:left;margin-right:10px;}
.last {margin-right:0;}
.span-1 {width:30px;}
.span-2 {width:70px;}
.span-3 {width:110px;}
.span-4 {width:150px;}
.span-5 {width:190px;}
.span-6 {width:230px;}
.span-7 {width:270px;}
.span-8 {width:310px;}
.span-9 {width:350px;}
.span-10 {width:390px;}
.span-11 {width:430px;}
.span-12 {width:470px;}
.span-13 {width:510px;}
.span-14 {width:550px;}
.span-15 {width:590px;}
.span-16 {width:630px;}
.span-17 {width:670px;}
.span-18 {width:710px;}
.span-19 {width:750px;}
.span-20 {width:790px;}
.span-21 {width:830px;}
.span-22 {width:870px;}
.span-23 {width:910px;}
.span-24 {width:950px;margin-right:0;}
input.span-1, textarea.span-1, input.span-2, textarea.span-2, input.span-3, textarea.span-3, input.span-4, textarea.span-4, input.span-5, textarea.span-5, input.span-6, textarea.span-6, input.span-7, textarea.span-7, input.span-8, textarea.span-8, input.span-9, textarea.span-9, input.span-10, textarea.span-10, input.span-11, textarea.span-11, input.span-12, textarea.span-12, input.span-13, textarea.span-13, input.span-14, textarea.span-14, input.span-15, textarea.span-15, input.span-16, textarea.span-16, input.span-17, textarea.span-17, input.span-18, textarea.span-18, input.span-19, textarea.span-19, input.span-20, textarea.span-20, input.span-21, textarea.span-21, input.span-22, textarea.span-22, input.span-23, textarea.span-23, input.span-24, textarea.span-24 {border-left-width:1px;border-right-width:1px;padding-left:5px;padding-right:5px;}
input.span-1, textarea.span-1 {width:18px;}
input.span-2, textarea.span-2 {width:58px;}
input.span-3, textarea.span-3 {width:98px;}
input.span-4, textarea.span-4 {width:138px;}
input.span-5, textarea.span-5 {width:178px;}
input.span-6, textarea.span-6 {width:218px;}
input.span-7, textarea.span-7 {width:258px;}
input.span-8, textarea.span-8 {width:298px;}
input.span-9, textarea.span-9 {width:338px;}
input.span-10, textarea.span-10 {width:378px;}
input.span-11, textarea.span-11 {width:418px;}
input.span-12, textarea.span-12 {width:458px;}
input.span-13, textarea.span-13 {width:498px;}
input.span-14, textarea.span-14 {width:538px;}
input.span-15, textarea.span-15 {width:578px;}
input.span-16, textarea.span-16 {width:618px;}
input.span-17, textarea.span-17 {width:658px;}
input.span-18, textarea.span-18 {width:698px;}
input.span-19, textarea.span-19 {width:738px;}
input.span-20, textarea.span-20 {width:778px;}
input.span-21, textarea.span-21 {width:818px;}
input.span-22, textarea.span-22 {width:858px;}
input.span-23, textarea.span-23 {width:898px;}
input.span-24, textarea.span-24 {width:938px;}
.append-1 {padding-right:40px;}
.append-2 {padding-right:80px;}
.append-3 {padding-right:120px;}
.append-4 {padding-right:160px;}
.append-5 {padding-right:200px;}
.append-6 {padding-right:240px;}
.append-7 {padding-right:280px;}
.append-8 {padding-right:320px;}
.append-9 {padding-right:360px;}
.append-10 {padding-right:400px;}
.append-11 {padding-right:440px;}
.append-12 {padding-right:480px;}
.append-13 {padding-right:520px;}
.append-14 {padding-right:560px;}
.append-15 {padding-right:600px;}
.append-16 {padding-right:640px;}
.append-17 {padding-right:680px;}
.append-18 {padding-right:720px;}
.append-19 {padding-right:760px;}
.append-20 {padding-right:800px;}
.append-21 {padding-right:840px;}
.append-22 {padding-right:880px;}
.append-23 {padding-right:920px;}
.prepend-1 {padding-left:40px;}
.prepend-2 {padding-left:80px;}
.prepend-3 {padding-left:120px;}
.prepend-4 {padding-left:160px;}
.prepend-5 {padding-left:200px;}
.prepend-6 {padding-left:240px;}
.prepend-7 {padding-left:280px;}
.prepend-8 {padding-left:320px;}
.prepend-9 {padding-left:360px;}
.prepend-10 {padding-left:400px;}
.prepend-11 {padding-left:440px;}
.prepend-12 {padding-left:480px;}
.prepend-13 {padding-left:520px;}
.prepend-14 {padding-left:560px;}
.prepend-15 {padding-left:600px;}
.prepend-16 {padding-left:640px;}
.prepend-17 {padding-left:680px;}
.prepend-18 {padding-left:720px;}
.prepend-19 {padding-left:760px;}
.prepend-20 {padding-left:800px;}
.prepend-21 {padding-left:840px;}
.prepend-22 {padding-left:880px;}
.prepend-23 {padding-left:920px;}
.border {padding-right:4px;margin-right:5px;border-right:1px solid #ddd;}
.colborder {padding-right:24px;margin-right:25px;border-right:1px solid #ddd;}
.pull-1 {margin-left:-40px;}
.pull-2 {margin-left:-80px;}
.pull-3 {margin-left:-120px;}
.pull-4 {margin-left:-160px;}
.pull-5 {margin-left:-200px;}
.pull-6 {margin-left:-240px;}
.pull-7 {margin-left:-280px;}
.pull-8 {margin-left:-320px;}
.pull-9 {margin-left:-360px;}
.pull-10 {margin-left:-400px;}
.pull-11 {margin-left:-440px;}
.pull-12 {margin-left:-480px;}
.pull-13 {margin-left:-520px;}
.pull-14 {margin-left:-560px;}
.pull-15 {margin-left:-600px;}
.pull-16 {margin-left:-640px;}
.pull-17 {margin-left:-680px;}
.pull-18 {margin-left:-720px;}
.pull-19 {margin-left:-760px;}
.pull-20 {margin-left:-800px;}
.pull-21 {margin-left:-840px;}
.pull-22 {margin-left:-880px;}
.pull-23 {margin-left:-920px;}
.pull-24 {margin-left:-960px;}
.pull-1, .pull-2, .pull-3, .pull-4, .pull-5, .pull-6, .pull-7, .pull-8, .pull-9, .pull-10, .pull-11, .pull-12, .pull-13, .pull-14, .pull-15, .pull-16, .pull-17, .pull-18, .pull-19, .pull-20, .pull-21, .pull-22, .pull-23, .pull-24 {float:left;position:relative;}
.push-1 {margin:0 -40px 1.5em 40px;}
.push-2 {margin:0 -80px 1.5em 80px;}
.push-3 {margin:0 -120px 1.5em 120px;}
.push-4 {margin:0 -160px 1.5em 160px;}
.push-5 {margin:0 -200px 1.5em 200px;}
.push-6 {margin:0 -240px 1.5em 240px;}
.push-7 {margin:0 -280px 1.5em 280px;}
.push-8 {margin:0 -320px 1.5em 320px;}
.push-9 {margin:0 -360px 1.5em 360px;}
.push-10 {margin:0 -400px 1.5em 400px;}
.push-11 {margin:0 -440px 1.5em 440px;}
.push-12 {margin:0 -480px 1.5em 480px;}
.push-13 {margin:0 -520px 1.5em 520px;}
.push-14 {margin:0 -560px 1.5em 560px;}
.push-15 {margin:0 -600px 1.5em 600px;}
.push-16 {margin:0 -640px 1.5em 640px;}
.push-17 {margin:0 -680px 1.5em 680px;}
.push-18 {margin:0 -720px 1.5em 720px;}
.push-19 {margin:0 -760px 1.5em 760px;}
.push-20 {margin:0 -800px 1.5em 800px;}
.push-21 {margin:0 -840px 1.5em 840px;}
.push-22 {margin:0 -880px 1.5em 880px;}
.push-23 {margin:0 -920px 1.5em 920px;}
.push-24 {margin:0 -960px 1.5em 960px;}
.push-1, .push-2, .push-3, .push-4, .push-5, .push-6, .push-7, .push-8, .push-9, .push-10, .push-11, .push-12, .push-13, .push-14, .push-15, .push-16, .push-17, .push-18, .push-19, .push-20, .push-21, .push-22, .push-23, .push-24 {float:left;position:relative;}
div.prepend-top, .prepend-top {margin-top:1.5em;}
div.append-bottom, .append-bottom {margin-bottom:1.5em;}
.box {padding:1.5em;margin-bottom:1.5em;background:#e5eCf9;}
hr {background:#ddd;color:#ddd;clear:both;float:none;width:100%;height:1px;margin:0 0 1.45em;border:none;}
hr.space {background:#fff;color:#fff;visibility:hidden;}
.clearfix:after, .container:after {content:"\0020";display:block;height:0;clear:both;visibility:hidden;overflow:hidden;}
.clearfix, .container {display:block;}
.clear {clear:both;}
END_OF_SRC

&main;exit;

sub _mkpath {
    my $d = shift;
    print "mkdir $d\n";
    mkpath $d;
}

sub main {
    $module = shift @ARGV or pod2usage(0);
    $module =~ s!-!::!g;

    # $module = "Foo::Bar"
    # $dist   = "Foo-Bar"
    # $path   = "Foo/Bar"
    my @pkg  = split /::/, $module;
    my $dist = join "-", @pkg;
    my $path = join "/", @pkg;

    mkdir $dist or die "Cannot mkdir '$dist': $!";
    chdir $dist or die $!;
    _mkpath "lib/$path";
    _mkpath "lib/$path/Web/";
    _mkpath "lib/$path/Web/C" unless $dispatcher eq 'Lite';
    _mkpath "lib/$path/M";
    _mkpath "lib/$path/DB/";
    _mkpath "tmpl";
    _mkpath "tmpl/include/";
    _mkpath "t";
    _mkpath "xt";
    _mkpath "sql/";
    _mkpath "config/";
    _mkpath "script/";
    _mkpath "script/cron/";
    _mkpath "script/tmp/";
    _mkpath "script/maintenance/";
    _mkpath "htdocs/static/css/";
    _mkpath "htdocs/static/img/";
    _mkpath "htdocs/static/js/";
    _mkpath "htdocs/static/blueprint/" if $blueprint;
    _mkpath "extlib/";

    my $conf = _parse_conf($confsrc);
    while (my ($file, $tmpl) = each %$conf) {
        $file =~ s/(\$\w+)/$1/gee;
        my $code = Text::MicroTemplate->new(
            tag_start => '<%',
            tag_end   => '%>',
            line_start => '%%%',
            template => $tmpl,
        )->code;
        my $sub = eval "package main;our \$module; sub { Text::MicroTemplate::encoded_string(($code)->(\@_))}";
        die $@ if $@;

        my $res = $sub->()->as_string;

        print "writing $file\n";
        open my $fh, '>', $file or die "Can't open file($file):$!";
        print $fh $res;
        close $fh;
    }
}

sub _parse_conf {
    my $fname;
    my $res;
    my $tag;
    LOOP: for my $line (split /\n/, $confsrc) {
        if ($line =~ /^--\s+(\S+)(?:\s*(\S+))?$/) {
            $fname = $1;
            $tag   = $2;
        } else {
            $fname or die "missing filename for first content";
            next LOOP if $tag && $tag eq 'skinny' && !$skinny;
            next LOOP if $tag && $tag eq 'blueprint' && !$blueprint;
            next LOOP if $tag && $tag eq 'RouterSimple' && $dispatcher ne 'RouterSimple';
            $res->{$fname} .= "$line\n";
        }
    }
    return $res;
}

__END__

=head1 SYNOPSIS

    % amon-setup.pl MyApp

=head1 AUTHOR

Tokuhiro Matsuno

=cut

