#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 17;

use Cwd 'cwd';
use File::Spec;
use File::Temp;

# "My cat's breath smells like cat food."
use_ok 'Mojo::Command';

my $command = Mojo::Command->new;

# UNIX DATA templates
my $unix = "@@ template1\nFirst Template\n@@ template2\r\nSecond Template\n";
open my $data, '<', \$unix;
no strict 'refs';
*{"Example::Package::UNIX::DATA"} = $data;
is $command->get_data('template1', 'Example::Package::UNIX'),
  "First Template\n", 'right template';
is $command->get_data('template2', 'Example::Package::UNIX'),
  "Second Template\n", 'right template';
is_deeply [sort keys %{$command->get_all_data('Example::Package::UNIX')}],
  [qw/template1 template2/], 'right DATA files';
close $data;

# Windows DATA templates
my $windows =
  "@@ template3\r\nThird Template\r\n@@ template4\r\nFourth Template\r\n";
open $data, '<', \$windows;
no strict 'refs';
*{"Example::Package::Windows::DATA"} = $data;
is $command->get_data('template3', 'Example::Package::Windows'),
  "Third Template\r\n", 'right template';
is $command->get_data('template4', 'Example::Package::Windows'),
  "Fourth Template\r\n", 'right template';
is_deeply [sort keys %{$command->get_all_data('Example::Package::Windows')}],
  [qw/template3 template4/], 'right DATA files';
close $data;

# Class to file and path
is $command->class_to_file('Foo::Bar'), 'foo_bar',    'right file';
is $command->class_to_path('Foo::Bar'), 'Foo/Bar.pm', 'right path';

# Environment detection
{
  local $ENV{PLACK_ENV} = 'production';
  is $command->detect, 'psgi', 'right environment';
}
{
  local $ENV{PATH_INFO} = '/test';
  is $command->detect, 'cgi', 'right environment';
}
{
  local $ENV{GATEWAY_INTERFACE} = 'CGI/1.1';
  is $command->detect, 'cgi', 'right environment';
}
{
  local %ENV = ();
  is $command->detect, 'fastcgi', 'right environment';
}

# Generating files
my $cwd = cwd;
my $dir = File::Temp::tempdir(CLEANUP => 1);
chdir $dir;
$command->create_rel_dir('foo/bar');
is -d File::Spec->catdir($dir, qw/foo bar/), 1, 'directory exists';
my $template = "@@ foo_bar\njust <%= 'works' %>!\n";
open $data, '<', \$template;
no strict 'refs';
*{"Mojo::Command::DATA"} = $data;
$command->render_to_rel_file('foo_bar', 'bar/baz.txt');
open my $txt, '<', $command->rel_file('bar/baz.txt');
is join('', <$txt>), "just works!\n", 'right result';
$command->chmod_rel_file('bar/baz.txt', 0700);
is -e $command->rel_file('bar/baz.txt'), 1, 'file is executable';
$command->write_rel_file('123.xml', "seems\nto\nwork");
open my $xml, '<', $command->rel_file('123.xml');
is join('', <$xml>), "seems\nto\nwork", 'right result';
chdir $cwd;
