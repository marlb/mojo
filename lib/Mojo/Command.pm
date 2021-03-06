package Mojo::Command;
use Mojo::Base -base;

require Cwd;
require File::Path;
require File::Spec;
require IO::File;

use Carp 'croak';
use Mojo::Server;
use Mojo::Template;
use Mojo::Loader;
use Mojo::Util qw/b64_decode camelize decamelize/;

has hint => <<"EOF";

See '$0 help COMMAND' for more information on a specific command.
EOF
has description => 'No description.';
has message     => <<"EOF";
usage: $0 COMMAND [OPTIONS]

Tip: CGI, FastCGI and PSGI environments can be automatically detected very
     often and work without commands.

These commands are currently available:
EOF
has namespaces => sub { ['Mojo::Command'] };
has quiet      => 0;
has renderer   => sub { Mojo::Template->new };
has usage      => "usage: $0\n";

# Cache
my $CACHE = {};

sub chmod_file {
  my ($self, $path, $mod) = @_;
  chmod $mod, $path or croak qq/Can't chmod path "$path": $!/;
  $mod = sprintf '%lo', $mod;
  print "  [chmod] $path $mod\n" unless $self->quiet;
  return $self;
}

sub chmod_rel_file {
  my ($self, $path, $mod) = @_;
  $self->chmod_file($self->rel_file($path), $mod);
}

sub class_to_file {
  my ($self, $class) = @_;
  $class =~ s/:://g;
  decamelize $class;
  return $class;
}

sub class_to_path {
  my ($self, $class) = @_;
  my $path = join '/', split /::/, $class;
  return "$path.pm";
}

sub create_dir {
  my ($self, $path) = @_;

  # Exists
  if (-d $path) {
    print "  [exist] $path\n" unless $self->quiet;
    return $self;
  }

  # Create
  File::Path::mkpath($path) or croak qq/Can't make directory "$path": $!/;
  print "  [mkdir] $path\n" unless $self->quiet;
  return $self;
}

sub create_rel_dir {
  my ($self, $path) = @_;
  $self->create_dir($self->rel_dir($path));
}

sub detect {
  my ($self, $guess) = @_;

  # PSGI (Plack only for now)
  return 'psgi' if defined $ENV{PLACK_ENV};

  # CGI
  return 'cgi'
    if defined $ENV{PATH_INFO} || defined $ENV{GATEWAY_INTERFACE};

  # No further detection if we have a guess
  return $guess if $guess;

  # FastCGI (detect absence of WINDIR for Windows and USER for UNIX)
  return 'fastcgi' if !defined $ENV{WINDIR} && !defined $ENV{USER};

  # Nothing
  return;
}

sub get_all_data {
  my ($self, $class) = @_;
  $class ||= ref $self;

  # Refresh or use cached data
  my $d = do { no strict 'refs'; \*{"$class\::DATA"} };
  return $CACHE->{$class} unless fileno $d;
  seek $d, 0, 0;
  my $content = join '', <$d>;
  close $d;

  # Ignore everything before __DATA__ (windows will seek to start of file)
  $content =~ s/^.*\n__DATA__\r?\n/\n/s;

  # Ignore everything after __END__
  $content =~ s/\n__END__\r?\n.*$/\n/s;

  # Split
  my @data = split /^@@\s+(.+?)\s*\r?\n/m, $content;
  shift @data;

  # Find data
  my $all = $CACHE->{$class} = {};
  while (@data) {
    my ($name, $content) = splice @data, 0, 2;
    b64_decode $content if $name =~ s/\s*\(\s*base64\s*\)$//;
    $all->{$name} = $content;
  }

  return $all;
}

sub get_data {
  my ($self, $data, $class) = @_;
  my $all = $self->get_all_data($class);
  return $all->{$data};
}

# "You don’t like your job, you don’t strike.
#  You go in every day and do it really half-assed. That’s the American way."
sub help {
  my $self = shift;
  print $self->usage;
  exit;
}

sub rel_dir {
  my ($self, $path) = @_;
  my @parts = split /\//, $path;
  return File::Spec->catdir(Cwd::getcwd(), @parts);
}

sub rel_file {
  my ($self, $path) = @_;
  my @parts = split /\//, $path;
  return File::Spec->catfile(Cwd::getcwd(), @parts);
}

sub render_data {
  my $self = shift;
  my $data = shift;
  $self->renderer->render($self->get_data($data), @_);
}

sub render_to_file {
  my $self = shift;
  my $data = shift;
  my $path = shift;
  $self->write_file($path, $self->render_data($data, @_));
  return $self;
}

sub render_to_rel_file {
  my $self = shift;
  my $data = shift;
  my $path = shift;
  $self->render_to_file($data, $self->rel_dir($path), @_);
}

sub run {
  my ($self, $name, @args) = @_;

  # Application loader
  return Mojo::Server->new->app if defined $ENV{MOJO_APP_LOADER};

  # Try to detect environment
  $name = $self->detect($name) unless $ENV{MOJO_NO_DETECT};

  # Run command
  if ($name && $name =~ /^\w+$/ && ($name ne 'help' || $args[0])) {

    # Help
    my $help = $name eq 'help' ? 1 : 0;
    $name = shift @args if $help;
    $help = 1           if $ENV{MOJO_HELP};

    # Try all namespaces
    my $module;
    for my $namespace (@{$self->namespaces}) {

      # Generate module
      my $camelized = $name;
      camelize $camelized;
      my $try = "$namespace\::$camelized";

      # Load
      if (my $e = Mojo::Loader->load($try)) {

        # Module missing
        next unless ref $e;

        # Real error
        die $e;
      }

      # Module is a command
      next unless $try->can('new') && $try->can('run');

      # Found
      $module = $try;
      last;
    }

    # Command missing
    die qq/Command "$name" missing, maybe you need to install it?\n/
      unless $module;

    # Run
    my $command = $module->new;
    return $help ? $command->help : $command->run(@args);
  }

  # Test
  return $self if $ENV{HARNESS_ACTIVE};

  # Try all namespaces
  my $commands = [];
  my $seen     = {};
  for my $namespace (@{$self->namespaces}) {

    # Search
    if (my $modules = Mojo::Loader->search($namespace)) {
      for my $module (@$modules) {

        # Load
        if (my $e = Mojo::Loader->load($module)) { die $e }

        # Seen
        my $command = $module;
        $command =~ s/^$namespace\:://;
        push @$commands, [$command => $module]
          unless $seen->{$command};
        $seen->{$command} = 1;
      }
    }
  }

  # Print overview
  print $self->message;

  # Make list
  my $list = [];
  my $len  = 0;
  foreach my $command (@$commands) {

    # Generate name
    my $name = $command->[0];
    decamelize $name;

    # Add to list
    my $l = length $name;
    $len = $l if $l > $len;
    push @$list, [$name, $command->[1]->new->description];
  }

  # Print list
  foreach my $command (@$list) {
    my $name        = $command->[0];
    my $description = $command->[1];
    my $padding     = ' ' x ($len - length $name);
    print "  $name$padding   $description";
  }
  print $self->hint;

  return $self;
}

sub start {
  my $self = shift;

  # Executable
  $ENV{MOJO_EXE} ||= (caller)[1] if $ENV{MOJO_APP};

  # Run
  my @args = @_ ? @_ : @ARGV;
  ref $self ? $self->run(@args) : $self->new->run(@args);
}

sub write_file {
  my ($self, $path, $data) = @_;

  # Directory
  my @parts = File::Spec->splitdir($path);
  pop @parts;
  my $dir = File::Spec->catdir(@parts);
  $self->create_dir($dir);

  # Write unbuffered
  croak qq/Can't open file "$path": $!/
    unless my $file = IO::File->new("> $path");
  $file->syswrite($data);
  print "  [write] $path\n" unless $self->quiet;

  return $self;
}

sub write_rel_file {
  my ($self, $path, $data) = @_;
  $self->write_file($self->rel_file($path), $data);
}

1;
__END__

=head1 NAME

Mojo::Command - Command Base Class

=head1 SYNOPSIS

  # Camel case command name
  package Mojo::Command::Mycommand;

  # Subclass
  use Mojo::Base 'Mojo::Command';

  # Take care of command line options
  use Getopt::Long 'GetOptions';

  # Short description
  has description => <<'EOF';
  My first Mojo command.
  EOF

  # Short usage message
  has usage => <<"EOF";
  usage: $0 mycommand [OPTIONS]

  These options are available:
    --something   Does something.
  EOF

  # <suitable Futurama quote here>
  sub run {
    my $self = shift;

    # Handle options
    local @ARGV = @_ if @_;
    GetOptions('something' => sub { $something = 1 });

    # Magic here! :)
  }

=head1 DESCRIPTION

L<Mojo::Command> is an abstract base class for L<Mojo> commands.

See L<Mojolicious::Commands> for a list of commands that are available by
default.

=head1 ATTRIBUTES

L<Mojo::Command> implements the following attributes.

=head2 C<description>

  my $description = $command->description;
  $command        = $command->description('Foo!');

Short description of command, used for the command list.

=head2 C<hint>

  my $hint  = $commands->hint;
  $commands = $commands->hint('Foo!');

Short hint shown after listing available commands.

=head2 C<message>

  my $message = $commands->message;
  $commands   = $commands->message('Hello World!');

Short usage message shown before listing available commands.

=head2 C<namespaces>

  my $namespaces = $commands->namespaces;
  $commands      = $commands->namespaces(['Mojolicious::Commands']);

Namespaces to search for available commands, defaults to L<Mojo::Command>.

=head2 C<quiet>

  my $quiet = $command->quiet;
  $command  = $command->quiet(1);

Limited command output.

=head2 C<usage>

  my $usage = $command->usage;
  $command  = $command->usage('Foo!');

Usage information for command, used for the help screen.

=head1 METHODS

L<Mojo::Command> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 C<chmod_file>

  $command = $command->chmod_file('/foo/bar.txt', 0644);

Portably change mode of a file.

=head2 C<chmod_rel_file>

  $command = $command->chmod_rel_file('foo/bar.txt', 0644);

Portably change mode of a relative file.

=head2 C<class_to_file>

  my $file = $command->class_to_file('Foo::Bar');

Convert a class name to a file.

  FooBar -> foo_bar

=head2 C<class_to_path>

  my $path = $command->class_to_path('Foo::Bar');

Convert class name to path.

  Foo::Bar -> Foo/Bar.pm

=head2 C<create_dir>

  $command = $command->create_dir('/foo/bar/baz');

Portably create a directory.

=head2 C<create_rel_dir>

  $command = $command->create_rel_dir('foo/bar/baz');

Portably create a relative directory.

=head2 C<detect>

  my $env = $commands->detect;
  my $env = $commands->detect($guess);

Try to detect environment.

=head2 C<get_all_data>

  my $all = $command->get_all_data;
  my $all = $command->get_all_data('Some::Class');

Extract all embedded files from the C<DATA> section of a class.

=head2 C<get_data>

  my $data = $command->get_data('foo_bar');
  my $data = $command->get_data('foo_bar', 'Some::Class');

Extract embedded file from the C<DATA> section of a class.

=head2 C<help>

  $command->help;

Print usage information for command.

=head2 C<rel_dir>

  my $path = $command->rel_dir('foo/bar');

Portably generate an absolute path from a relative UNIX style path.

=head2 C<rel_file>

  my $path = $command->rel_file('foo/bar.txt');

Portably generate an absolute path from a relative UNIX style path.

=head2 C<render_data>

  my $data = $command->render_data('foo_bar', @arguments);

Render a template from the C<DATA> section of the command class.

=head2 C<render_to_file>

  $command = $command->render_to_file('foo_bar', '/foo/bar.txt');

Render a template from the C<DATA> section of the command class to a file.

=head2 C<render_to_rel_file>

  $command = $command->render_to_rel_file('foo_bar', 'foo/bar.txt');

Portably render a template from the C<DATA> section of the command class to a
relative file.

=head2 C<run>

  $commands->run;
  $commands->run(@ARGV);

Load and run commands.

=head2 C<start>

  Mojo::Command->start;
  Mojo::Command->start(@ARGV);

Start the command line interface.

=head2 C<write_file>

  $command = $command->write_file('/foo/bar.txt', 'Hello World!');

Portably write text to a file.

=head2 C<write_rel_file>

  $command = $command->write_rel_file('foo/bar.txt', 'Hello World!');

Portably write text to a relative file.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
