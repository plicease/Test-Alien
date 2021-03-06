package Test::Alien;

use strict;
use warnings;
use 5.008001;
use Env qw( @PATH );
use File::Which 1.10 qw( which );
use if $^O ne 'MSWin32', 'Capture::Tiny' => 'capture_merged';
use Capture::Tiny qw( capture );
use File::Temp ();
use Carp qw( croak );
use File::Spec;
use File::Basename qw( dirname );
use File::Path qw( mkpath );
use File::Copy qw( move );
use Text::ParseWords qw( shellwords );
use Test2::API qw( context run_subtest );
use base qw( Exporter );

BEGIN {
  *capture_merged = sub (&;@)
  {
    # TODO: fix this error properly:
    #Error in tempfile() using template C:\Users\ollisg\AppData\Local\Temp\XXXXXXXXXX: Could not create temp file C:\Users\ollisg\AppData\Local\Temp\eysiq7e9w5: Permission denied at N:/home/ollisg/perl5/straw
    # rry/x86/5.22.1/lib/perl5/Capture/Tiny.pm line 360.
    
    # this seems to work more reliably on windows, at the cost of being much noisier.
    my $code = shift;
    wantarray ? ('', $code->(@_)) : '';
  } if $^O eq 'MSWin32';
}

our @EXPORT = qw( alien_ok run_ok xs_ok ffi_ok with_subtest synthetic );

# ABSTRACT: Testing tools for Alien modules
# VERSION

=head1 SYNOPSIS

B<NOTE>: this distribution has been ended.  L<Test::Alien> and the other modules that used to be distributed with this distribution can now be found as part of the C<Alien-Build> distribution.

Test commands that come with your Alien:

 use Test2::V0;
 use Test::Alien;
 use Alien::patch;
 
 alien_ok 'Alien::patch';
 run_ok([ 'patch', '--version' ])
   ->success
   # we only accept the version written
   # by Larry ...
   ->out_like(qr{Larry Wall}); 
 
 done_testing;

Test that your library works with C<XS>:

 use Test2::V0;
 use Test::Alien;
 use Alien::Editline;
 
 alien_ok 'Alien::Editline';
 my $xs = do { local $/; <DATA> };
 xs_ok $xs, with_subtest {
   my($module) = @_;
   ok $module->version;
 };
 
 done_testing;

 __DATA__
 
 #include "EXTERN.h"
 #include "perl.h"
 #include "XSUB.h"
 #include <editline/readline.h>
 
 const char *
 version(const char *class)
 {
   return rl_library_version;
 }
 
 MODULE = TA_MODULE PACKAGE = TA_MODULE
 
 const char *version(class);
     const char *class;

Test that your library works with L<FFI::Platypus>:

 use Test2::V0;
 use Test::Alien;
 use Alien::LibYAML;
 
 alien_ok 'Alien::LibYAML';
 ffi_ok { symbols => ['yaml_get_version'] }, with_subtest {
   my($ffi) = @_;
   my $get_version = $ffi->function(yaml_get_version => ['int*','int*','int*'] => 'void');
   $get_version->call(\my $major, \my $minor, \my $patch);
   like $major, qr{[0-9]+};
   like $minor, qr{[0-9]+};
   like $patch, qr{[0-9]+};
 };
 
 done_testing;

=head1 DESCRIPTION

This module provides tools for testing L<Alien> modules.  It has hooks
to work easily with L<Alien::Base> based modules, but can also be used
via the synthetic interface to test non L<Alien::Base> based L<Alien>
modules.  It has very modest prerequisites.

Prior to this module the best way to test a L<Alien> module was via L<Test::CChecker>.
The main downside to that module is that it is heavily influenced by and uses
L<ExtUtils::CChecker>, which is a tool for checking at install time various things
about your compiler.  It was also written before L<Alien::Base> became as stable as it
is today.  In particular, L<Test::CChecker> does its testing by creating an executable
and running it.  Unfortunately Perl uses extensions by creating dynamic libraries
and linking them into the Perl process, which is different in subtle and error prone
ways.  This module attempts to test the libraries in the way that they will actually
be used, via either C<XS> or L<FFI::Platypus>.  It also provides a mechanism for
testing binaries that are provided by the various L<Alien> modules (for example
L<Alien::gmake> and L<Alien::patch>).

L<Alien> modules can actually be useable without a compiler, or without L<FFI::Platypus>
(for example, if the library is provided by the system, and you are using L<FFI::Platypus>,
or if you are building from source and you are using C<XS>), so tests with missing
prerequisites are automatically skipped.  For example, L</xs_ok> will automatically skip
itself if a compiler is not found, and L</ffi_ok> will automatically skip itself
if L<FFI::Platypus> is not installed.

=head1 FUNCTIONS

=head2 alien_ok

 alien_ok $alien, $message;
 alien_ok $alien;

Load the given L<Alien> instance or class.  Checks that the instance or class conforms to the same
interface as L<Alien::Base>.  Will be used by subsequent tests.  The C<$alien> module only needs to
provide these methods in order to conform to the L<Alien::Base> interface:

=over 4

=item cflags

String containing the compiler flags

=item libs

String containing the linker and library flags

=item dynamic_libs

List of dynamic libraries.  Returns empty list if the L<Alien> module does not provide this.

=item bin_dir

Directory containing tool binaries.  Returns empty list if the L<Alien> module does not provide
this.

=back

If your L<Alien> module does not conform to this interface then you can create a synthetic L<Alien>
module using the L</synthetic> function.

=cut

our @aliens;

sub alien_ok ($;$)
{
  my($alien, $message) = @_;

  my $name = ref $alien ? ref($alien) . '[instance]' : $alien;
  
  my @methods = qw( cflags libs dynamic_libs bin_dir );
  $message ||= "$name responds to: @methods";
  my @missing = grep { ! $alien->can($_) } @methods;
  
  my $ok = !@missing;
  my $ctx = context();
  $ctx->ok($ok, $message);
  $ctx->diag("  missing method $_") for @missing;
  $ctx->release;
  
  if($ok)
  {
    push @aliens, $alien;
    unshift @PATH, $alien->bin_dir;
  }
  
  $ok;
}

=head2 synthetic

 my $alien = synthetic \%config;

Create a synthetic L<Alien> module which can be passed into L</alien_ok>.  C<\%config>
can contain these keys (all of which are optional):

=over 4

=item cflags

String containing the compiler flags.

=item cflags_static

String containing the static compiler flags (optional).

=item libs

String containing the linker and library flags.

=item libs_static

String containing the static linker flags (optional).

=item dynamic_libs

List reference containing the dynamic libraries.

=item bin_dir

Tool binary directory.

=back

See L<Test::Alien::Synthetic> for more details.

=cut

sub synthetic
{
  my($opt) = @_;
  $opt ||= {};
  my %alien = %$opt;
  require Test::Alien::Synthetic;
  bless \%alien, 'Test::Alien::Synthetic', 
}

=head2 run_ok

 my $run = run_ok $command;
 my $run = run_ok $command, $message;

Runs the given command, falling back on any C<Alien::Base#bin_dir> methods provided by L<Alien> modules
specified with L</alien_ok>.

C<$command> can be either a string or an array reference.

Only fails if the command cannot be found, or if it is killed by a signal!  Returns a L<Test::Alien::Run>
object, which you can use to test the exit status, output and standard error.

Always returns an instance of L<Test::Alien::Run>, even if the command could not be found.

=cut

sub run_ok
{
  my($command, $message) = @_;
  
  my(@command) = ref $command ? @$command : ($command);
  $message ||= "run @command";
  
  require Test::Alien::Run;
  my $run = bless {
    out    => '',
    err    => '',
    exit   => 0,
    sig    => 0,
    cmd    => [@command],
  }, 'Test::Alien::Run';
  
  my $ctx = context();
  my $exe = which $command[0];
  if(defined $exe)
  {
    shift @command;
    $run->{cmd} = [$exe, @command];
    my @diag;
    my $ok = 1;
    my($exit, $errno);
    ($run->{out}, $run->{err}, $exit, $errno) = capture { system $exe, @command; ($?,$!); };
  
    if($exit == -1)
    {
      $ok = 0;
      $run->{fail} = "failed to execute: $errno";
      push @diag, "  failed to execute: $errno";
    }
    elsif($exit & 127)
    {
      $ok = 0;
      push @diag, "  killed with signal: @{[ $exit & 127 ]}";
      $run->{sig} = $exit & 127;
    }
    else
    {
      $run->{exit} = $exit >> 8;
    }

    $ctx->ok($ok, $message);
    $ok 
      ? $ctx->note("  using $exe") 
      : $ctx->diag("  using $exe");
    $ctx->diag(@diag) for @diag;

  }
  else
  {
    $ctx->ok(0, $message);
    $ctx->diag("  command not found");
    $run->{fail} = 'command not found';
  }
  
  $ctx->release;
  
  $run;
}

=head2 xs_ok

 xs_ok $xs;
 xs_ok $xs, $message;

Compiles, links the given C<XS> code and attaches to Perl.

If you use the special module name C<TA_MODULE> in your C<XS>
code, it will be replaced by an automatically generated
package name.  This can be useful if you want to pass the same
C<XS> code to multiple calls to C<xs_ok> without subsequent
calls replacing previous ones.

C<$xs> may be either a string containing the C<XS> code,
or a hash reference with these keys:

=over 4

=item xs

The XS code.  This is the only required element.

=item pxs

The L<ExtUtils::ParseXS> arguments passes as a hash reference.

=item verbose

Spew copious debug information via test note.

=back

You can use the C<with_subtest> keyword to conditionally
run a subtest if the C<xs_ok> call succeeds.  If C<xs_ok>
does not work, then the subtest will automatically be
skipped.  Example:

 xs_ok $xs, with_subtest {
   # skipped if $xs fails for some reason
   my($module) = @_;
   plan 1;
   is $module->foo, 1;
 };

The module name detected during the XS parsing phase will
be passed in to the subtest.  This is helpful when you are
using a generated module name.

=cut

sub _flags
{
  my($class, $method) = @_;
  my $static = "${method}_static";
  $class->can($static) && $class->can('install_type') && $class->install_type eq 'share'
    ? $class->$static
    : $class->$method;
}

sub xs_ok
{
  my $cb;
  $cb = pop if defined $_[-1] && ref $_[-1] eq 'CODE';
  my($xs, $message) = @_;
  $message ||= 'xs';

  require ExtUtils::CBuilder;
  my $skip = !ExtUtils::CBuilder->new->have_compiler;

  if($skip)
  {
    my $ctx = context();
    $ctx->skip($message, 'test requires a compiler');
    $ctx->skip("$message subtest", 'test requires a compiler') if $cb;
    $ctx->release;
    return;
  }
  
  $xs = { xs => $xs } unless ref $xs;
  # make sure this is a copy because we may
  # modify it.
  $xs->{xs} = "@{[ $xs->{xs} ]}";
  $xs->{pxs} ||= {};
  my $verbose = $xs->{verbose};
  my $ok = 1;
  my @diag;
  my $dir = _tempdir( CLEANUP => 1, TEMPLATE => 'testalienXXXXX' );
  my $xs_filename = File::Spec->catfile($dir, 'test.xs');
  my $c_filename  = File::Spec->catfile($dir, 'test.c');
  
  my $ctx = context();
  my $module;

  if($xs->{xs} =~ /\bTA_MODULE\b/)
  {
    our $count;
    $count = 0 unless defined $count;
    my $name = sprintf "Test::Alien::XS::Mod%s", $count++;
    my $code = $xs->{xs};
    $code =~ s{\bTA_MODULE\b}{$name}g;
    $xs->{xs} = $code;
  }

  # this regex copied shamefully from ExtUtils::ParseXS
  # in part because we need the module name to do the bootstrap
  # and also because if this regex doesn't match then ParseXS
  # does an exit() which we don't want.
  if($xs->{xs} =~ /^MODULE\s*=\s*([\w:]+)(?:\s+PACKAGE\s*=\s*([\w:]+))?(?:\s+PREFIX\s*=\s*(\S+))?\s*$/m)
  {
    $module = $1;
    $ctx->note("detect module name $module") if $verbose;
  }
  else
  {
    $ok = 0;
    push @diag, '  XS does not have a module decleration that we could find';
  }

  if($ok)
  {
    open my $fh, '>', $xs_filename;
    print $fh $xs->{xs};
    close $fh;
  
    require ExtUtils::ParseXS;
    my $pxs = ExtUtils::ParseXS->new;
  
    my($out, $err) = capture_merged {
      eval {
        $pxs->process_file(
          filename     => $xs_filename,
          output       => $c_filename,
          versioncheck => 0,
          prototypes   => 0,
          %{ $xs->{pxs} },
        );
      };
      $@;
    };
    
    $ctx->note("parse xs $xs_filename => $c_filename") if $verbose;
    $ctx->note($out) if $verbose;
    $ctx->note("error: $err") if $verbose && $err;

    unless($pxs->report_error_count == 0)
    {
      $ok = 0;
      push @diag, '  ExtUtils::ParseXS failed:';
      push @diag, "    $err" if $err;
      push @diag, "    $_" for split /\r?\n/, $out;
    }
  }

  if($ok)
  {
    my $cb = ExtUtils::CBuilder->new;

    my($out, $obj, $err) = capture_merged {
      my $obj = eval {
        $cb->compile(
          source               => $c_filename,
          extra_compiler_flags => [shellwords map { _flags $_, 'cflags' } @aliens],
        );
      };
      ($obj, $@);
    };
    
    $ctx->note("compile $c_filename") if $verbose;
    $ctx->note($out) if $verbose;
    $ctx->note($err) if $verbose && $err;
    
    unless($obj)
    {
      $ok = 0;
      push @diag, '  ExtUtils::CBuilder->compile failed';
      push @diag, "    $err" if $err;
      push @diag, "    $_" for split /\r?\n/, $out;
    }
    
    if($ok)
    {
    
      my($out, $lib, $err) = capture_merged {
        my $lib = eval { 
          $cb->link(
            objects            => [$obj],
            module_name        => $module,
            extra_linker_flags => [shellwords map { _flags $_, 'libs' } @aliens],
          );
        };
        ($lib, $@);
      };
      
      $ctx->note("link $obj") if $verbose;
      $ctx->note($out) if $verbose;
      $ctx->note($err) if $verbose && $err;
      
      if($lib)
      {
        $ctx->note("created lib $lib") if $xs->{verbose};
      }
      else
      {
        $ok = 0;
        push @diag, '  ExtUtils::CBuilder->link failed';
        push @diag, "    $err" if $err;
        push @diag, "    $_" for split /\r?\n/, $out;
      }
      
      if($ok)
      {
        require Config;
        my @modparts = split(/::/,$module);
        my $dl_dlext = $Config::Config{dlext};
        my $modfname = $modparts[-1];

        my $libpath = File::Spec->catfile($dir, 'auto', @modparts, "$modfname.$dl_dlext");
        mkpath(dirname($libpath), 0, 0700);
        move($lib, $libpath) || die "unable to copy $lib => $libpath $!";
        
        pop @modparts;
        my $pmpath = File::Spec->catfile($dir, @modparts, "$modfname.pm");
        mkpath(dirname($pmpath), 0, 0700);
        open my $fh, '>', $pmpath;
        print $fh '# line '. __LINE__ . ' "' . __FILE__ . qq("\n) . qq{
          package $module;
          
          use strict;
          use warnings;
          require XSLoader;
          our \$VERSION = '0.01';
          XSLoader::load('$module','\$VERSION');
          
          1;
        };
        close $fh;

        {
          local @INC = @INC;
          unshift @INC, $dir;
          eval '# line '. __LINE__ . ' "' . __FILE__ . qq("\n) . qq{
            use $module;
          };
        }
        
        if(my $error = $@)
        {
          $ok = 0;
          push @diag, '  DynaLoader failed';
          push @diag, "    $error";
        }
      }
    }
  }

  $ctx->ok($ok, $message);
  $ctx->diag($_) for @diag;
  $ctx->release;
  
  if($cb)
  {
    $cb = sub {
      my $ctx = context();
      $ctx->plan(0, 'SKIP', "subtest requires xs success");
      $ctx->release;
    } unless $ok;

    @_ = ("$message subtest", $cb, 1, $module);

    goto \&Test2::API::run_subtest;
  }

  $ok;
}

sub with_subtest (&) { $_[0]; }

=head2 ffi_ok

 ffi_ok;
 ffi_ok \%opt;
 ffi_ok \%opt, $message;

Test that L<FFI::Platypus> works.

C<\%opt> is a hash reference with these keys (all optional):

=over 4

=item symbols

List references of symbols that must be found for the test to succeed.

=item ignore_not_found

Ignores symbols that aren't found.  This affects functions accessed via
L<FFI::Platypus#attach> and L<FFI::Platypus#function> methods, and does
not influence the C<symbols> key above.

=item lang

Set the language.  Used primarily for language specific native types.

=back

As with L</xs_ok> above, you can use the C<with_subtest> keyword to specify
a subtest to be run if C<ffi_ok> succeeds (it will skip otherwise).  The
L<FFI::Platypus> instance is passed into the subtest as the first argument.
For example:

 ffi_ok with_subtest {
   my($ffi) = @_;
   is $ffi->function(foo => [] => 'void')->call, 42;
 };

=cut

sub ffi_ok
{
  my $cb;
  $cb = pop if defined $_[-1] && ref $_[-1] eq 'CODE';
  my($opt, $message) = @_;
  
  $message ||= 'ffi';
  
  my $ok = 1;
  my $skip;
  my $ffi;
  my @diag;
  
  {
    my $min = '0.12'; # the first CPAN release
    $min = '0.15' if $opt->{ignore_not_found};
    $min = '0.18' if $opt->{lang};
    eval qq{ use FFI::Platypus $min };
    if($@)
    {
      $ok = 0;
      $skip = "Test requires FFI::Platypus $min";
    }
  }
  
  if($ok && $opt->{lang})
  {
    my $class = "FFI::Platypus::Lang::@{[ $opt->{lang} ]}";
    eval qq{ use $class () };
    if($@)
    {
      $ok = 0;
      $skip = "Test requires FFI::Platypus::Lang::@{[ $opt->{lang} ]}";
    }
  }
  
  if($ok)
  {
    $ffi = FFI::Platypus->new(
      lib              => [map { $_->dynamic_libs } @aliens],
      ignore_not_found => $opt->{ignore_not_found},
      lang             => $opt->{lang},
    );
    foreach my $symbol (@{ $opt->{symbols} || [] })
    {
      unless($ffi->find_symbol($symbol))
      {
        $ok = 0;
        push @diag, "  $symbol not found"
      }
    }
  }
  
  my $ctx = context(); 
  
  if($skip)
  {
    $ctx->skip($message, $skip);
  }
  else
  {
    $ctx->ok($ok, $message);
  }
  $ctx->diag($_) for @diag;
  
  $ctx->release;

  if($cb)
  {
    $cb = sub {
      my $ctx = context();
      $ctx->plan(0, 'SKIP', "subtest requires ffi success");
      $ctx->release;
    } unless $ok;

    @_ = ("$message subtest", $cb, 1, $ffi);

    goto \&Test2::API::run_subtest;
  }
  
  $ok;
}

sub _tempdir
{
  # makes sure /tmp or whatever isn't mounted noexec,
  # which will cause xs_ok tests to fail.

  my $dir = File::Temp::tempdir(@_);

  if($^O ne 'MSWin32')
  {
    my $filename = File::Spec->catfile($dir, 'foo.pl');
    my $fh;
    open $fh, '>', $filename;
    print $fh "#!$^X";
    close $fh;
    chmod 0755, $filename;
    system $filename, 'foo';
    if($?)
    {
      $dir = File::Temp::tempdir( DIR => File::Spec->curdir );
    }
  }
  
  $dir;  
}

1;

=head1 SEE ALSO

=over 4

=item L<Alien>

=item L<Alien::Base>

=item L<Alien::Build>

=item L<alienfile>

=item L<Test2>

=item L<Test::Alien::Run>

=item L<Test::Alien::CanCompile>

=item L<Test::Alien::CanPlatypus>

=item L<Test::Alien::Synthetic>

=back

=cut
