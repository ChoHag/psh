package Psh2;

use strict;

if ($^O eq 'MSWin32') {
    require Psh2::Windows;
} else {
    require Psh2::Unix;
}

*gt= *gt_dummy;

require POSIX;
require Psh2::Parser;

sub AUTOLOAD {
    no strict;
    $AUTOLOAD=~ s/.*:://g;
    my $ospackage= $^O eq 'MSWin32'?'Psh2::Windows':'Psh2::Unix';
    my $name= "${ospackage}::$AUTOLOAD";
    unless (ref *{$name}{CODE} eq 'CODE') {
	require Carp;
	Carp::croak("Function `$AUTOLOAD' does not exist.");
    }
    *$AUTOLOAD= *$name;
    goto &$AUTOLOAD;
}

sub DESTROY {}

sub new {
    my ($class)= @_;
    my $self= {
	       option =>
	       {
		array_exports =>
		{
		 path => path_separator(),
		 classpath => path_separator(),
		 ld_library_path => path_separator(),
		 fignore => path_separator(),
		 cdpath => path_separator(),
		 ls_colors => ':'
	     },
		frontend => 'readline',
	    },
	       cache => {
			 path => {},
			 command => {},
		     },
	       strategy => [],
	       language => { 'perl' => 1, 'c' => 1},
	       aliases  => {},
	       function => {},
	       dirstack => [],
	       dirstack_pos => 0,
	       tmp => {},
	       status => 0,
	   };
    bless $self, $class;
    return $self;
}

sub _eval {
    my $self= shift;
    my $lines= shift;

    while (my $element= shift @$lines) {
	my $type= shift @$element;
	if ($type == Psh2::Parser::T_EXECUTE()) {
	    $self->{status}= $self->start_job($element);
	}
	elsif ($type == Psh2::Parser::T_OR()) {
	    return if $self->{status};
	}
	elsif ($type == Psh2::Parser::T_AND()) {
	    return unless $self->{status};
	}
	else {
	    # TODO: Error handling
	}
    }
    return;
}

sub process {
    my ($self, $getter)= @_;

    my @store=();
    LINE: while (1) {
	my $input= &$getter();

	unless (defined $input) {
	    last;
	}
	my $tmp= eval { Psh2::Parser::parse_line($self, join("\n",@store, $input)); };
	if ($@) {
	    print STDERR $@;
	    if (substr($@,0,16) eq 'parse: needmore:') {
		push @store, $input;
		next LINE;
	    }
	}
	@store= ();

	if ($tmp and @$tmp) {
	    _eval($self, $tmp);
	}
	$self->reap_children();
    }
}

sub process_file {
    my ($self, $file)= @_;
    local $self->{interactive}= 0;
    local (*FILE);
    open( FILE, "< $file");
    $self->process( sub { my $txt=<FILE>; chomp($txt) if defined $txt; $txt});
    close( FILE);
}

sub process_args {
    my $self= shift;
    foreach my $arg (@_) {
	if (-r $arg) {
	    $self->process_file($arg);
	}
    }
}

sub process_variable {
    my $self= shift;
    my $var= shift;
    my @lines;
    if (ref $var eq 'ARRAY') {
	@lines= @$var;
    } else {
	@lines= split /\n/, $var;
    }
    $self->process(sub { shift @lines });
}

sub process_rc {
    my ($self)= @_;
    foreach my $file ('/etc/psh2rc', "$ENV{HOME}/.psh2/rc") {
	if (-r $file) {
	    $self->process_file($file);
	}
    }
}

sub main_loop {
    my $self= shift;

    $self->{interactive}= (-t STDIN) and (-t STDOUT);

    my $getter;
    if ($self->{interactive}) {
	$getter= sub { $self->fe->getline(@_) };
    } else {
	$getter= sub { return <STDIN>; };
    }
    $self->process($getter);
    exit 0;
}

sub init_minimal {
    my $self= shift;
    build_builtin_list($self);
    $| = 1;
    if (!$ENV{HOME}) {
	$ENV{HOME}= $self->get_home_dir();
    }
    setup_signal_handlers();
}

sub init_finish {
    my $self= shift;
    if ($self->{option}{locale}) {
	require Locale::gettext;
	Locale::gettext::textdomain('psh2');
	*gt= *gt_locale;
    } else {
	*gt= *gt_dummy;
    }
}

sub init_interactive {
    my $self= shift;
    my $frontend_name= 'Psh2::Frontend::'.ucfirst($self->{option}{frontend});
    eval "require $frontend_name";
    if ($@) {
	print STDERR $@;
	# TODO: Error handling
    }
    $self->{frontend}= $frontend_name->new($self);
    $self->fe->init();
    setup_signal_handlers();
}

############################################################################
##
## Input/Output
##
############################################################################

sub gt_dummy {
    if (@_ and ref $_[0]) {
	shift @_;
    }
    return $_[0];
}

sub gt_locale {
    if (@_ and ref $_[0]) {
	shift @_;
    }
    return Locale::gettext($_[0]);
}

sub print {
    my $self= shift;
    if ($self->fe) {
	$self->fe->print(0, @_);
    } else {
	CORE::print STDOUT @_;
    }
}

sub printf {
    my $self= shift;
    my $format= shift;
    $self->print(sprintf($format,@_));
}

sub println {
    my $self= shift;
    $self->print(@_,"\n");
}

sub printerr {
    my $self= shift;
    if ($self->fe) {
	$self->fe->print(1, @_);
    } else {
	CORE::print STDERR @_;
    }
}

sub printerrln {
    my $self= shift;
    $self->printerr(@_,"\n");
}

sub printferr {
    my $self= shift;
    my $format= shift;
    $self->printerr(sprintf($format,@_));
}

sub printferrln {
    my $self= shift;
    my $format= shift;
    $self->printerrln(sprintf($format,@_));
}

sub printdebug {
    my $self= shift;
    my $debugclass= shift;
    return if !$self->{option}{debug} or
	($self->{option}{debug} ne '1' and
	 $self->{option}{debug} !~ /\Q$debugclass\E/);

    if ($self->fe) {
	$self->fe->print(2, @_);
    } else {
	CORE::print STDERR @_;
    }
}

############################################################################
##
## Filehandling
##
############################################################################

{
    sub abs_path {
	my ($self, $path)= @_;
	return undef unless $path;
	return $self->{cache}{path}{$path} if $self->{cache}{path}{$path};

	my $result;
	if ($^O eq 'MSWin32' and defined &Win32::GetFullPathName) {
	    $result= Win32::GetFullPathName($path);
	    $result=~ tr:\\:/:;
	} else {
	    if ($path eq '~') {
		$result= $ENV{HOME};
	    }
	    elsif ( substr($path, 0, 2) eq '~/') {
		substr($path,0,1)= $ENV{HOME};
	    }
	    elsif ( substr($path, 0, 1) eq '~') {
		my $fs= file_separator();
		my ($user)= $path=~ /^\~(.*?)$fs/;
		if ($user) {
		    substr($path,0,length($user)+1)= get_home_dir($user);
		}
	    }
	    unless ($result) {
		my $tmp= rel2abs( $self, $path, $ENV{PWD});
		my $old= $ENV{PWD};
		if ($tmp and -r $tmp) {
		    if (-d $tmp and -x _) {
			if (CORE::chdir($tmp)) {
			    $result= getcwd();
			    if (!CORE::chdir($old)) {
				# TODO: Error handling
			    }
			}
		    } else {
			$result= $tmp;
		    }
		}
		return undef unless $result;
	    }
	}
	if ($result) {
	    $result.='/' if index($result,'/')==-1 and
	      index($result,'\\')==-1;
	}
	$self->{cache}{path}{$path}= $result if
	  file_name_is_absolute($self, $path);
	return $result;
    }


    my $tmp= quotemeta(file_separator());
    my $re= qr/^(.*)$tmp([^$tmp]+)$/;
    my $last_path_cwd;
    my $needs_path_recalc= 1;
    my @absed_path;

    sub which {
	my ($self, $command, $all_flag)= @_;
	return undef unless $command;

	if (index($command, file_separator())>-1) {
	    $command=~ $re;
	    my $path_element= $1 || '';
	    my $cmd_element = $2 || '';

	    return undef unless $path_element and $cmd_element;
	    $path_element= abs_path($self, $path_element);
	    my $try= catfile_fast($path_element, $cmd_element);
	    if (-x $try and ! -d _ ) {
		return $try;
	    }
	    return undef;
	}
	return $self->{cache}{command}{$command} if !$all_flag and exists $self->{cache}{command}{$command};

	return undef if $command !~ /^[\-a-zA-Z0-9_.~+]+$/;

	if ($needs_path_recalc and
	    (!@absed_path or $last_path_cwd ne ($ENV{PATH}.$ENV{PWD}))) {
	    $last_path_cwd= $ENV{PATH}.$ENV{PWD};
	    _recalc_absed_path($self);
	}
	my $path_ext= get_path_extension();
	my @all= ();
	foreach my $dir (@absed_path) {
	    next unless $dir;
	    my $try= catfile_fast($dir, $command);
	    foreach my $ext (@$path_ext) {
		my $tmp= $try.$ext;
		if (-x $tmp and !-d _) {
		    $self->{cache}{command}{$command}= $tmp;
		    return $tmp unless $all_flag;
		    push @all, $tmp;
		}
	    }
	}
	if ($all_flag and @all) {
	    return @all;
	}
	$self->{cache}{command}{$command}= undef;
	# speeds up locating non-commands
	return undef;
    }

    sub _recalc_absed_path {
	my $self= shift;

	@absed_path= ();
	my @path= split path_separator(), $ENV{PATH};
	$needs_path_recalc=0;
	eval {
	    foreach my $dir (@path) {
		next unless $dir;
		if (!file_name_is_absolute($self,$dir)) {
		    $needs_path_recalc=1;
		}
		$dir= abs_path($self, $dir);
		next unless $dir and -r $dir and -x _;
		push @absed_path, $dir;
	    }
	};
	print $@ if $@;
	# TODO: Error handling
    }
}

# recursive glob function used for **/anything glob
sub _recursive_glob {
    my( $pattern, $dir)= @_;
    opendir( DIR, $dir) || return ();
    my @files= readdir(DIR);
    closedir( DIR);
    $pattern= qr{^$pattern$};
    my @result= map { catdir_fast($dir,$_) }
      grep { $_ =~ $pattern } @files;
    foreach my $tmp (@files) {
	next if $tmp eq '.' or $tmp eq '..';
	my $tmpdir= catdir_fast($dir,$tmp);
	next if ! -d $tmpdir;
	push @result, _recursive_glob($pattern, $tmpdir);
    }
    return @result;
}

sub _escape {
    my $text= shift;
    $text=~s/(?<!\\)([^a-zA-Z0-9\*\?\/])/\\$1/g;
    return $text;
}

#
# The Perl builtin glob STILL uses csh, furthermore it is
# not possible to supply a base directory... so I guess this
# is faster
#

sub _glob {
    my ($level, $dir, $auto_recurse, $opts, @re)= @_;
    $level++;
    if ($level>20) {
	die "glob: too deep recursion!";
    }

    opendir(DIR, $dir) or return ();
    my @files= grep { $_ ne '.' and $_ ne '..' } readdir(DIR);
    closedir(DIR);

    my @results=();
    my $regexp= $re[0];
    if ($regexp eq '.*.*' or $regexp eq '**') {
	if ($auto_recurse) {
	    die "No double auto-recurse possible!";
	}
	shift @re;
	if (!@re) {
	    @re= ('.*');
	}
	@files= map { catdir_fast($dir,$_)} @files;
	foreach my $tmp (@files, $dir) {
	    if (-d $tmp) {
		push @results, _glob($level, $tmp, 1, $opts, @re);
	    }
	}
	return @results;
    }
    my $cpat;
    if ($opts->{i}) {
	$cpat= qr/^$regexp$/i;
    } else {
	$cpat= qr/^$regexp$/;
    }
    if (substr($regexp,0,2) ne "\\.") {
	@files= grep { substr($_,0,1) ne '.' } @files;
    }
    if ($auto_recurse) {
	foreach (@files) {
	    my $tmp= catdir_fast($dir,$_);
	    if (-d $tmp) {
		push @results, _glob($level, $tmp, 1, $opts, @re);
	    }
	}
    }
    @files= map { catdir_fast($dir,$_) } grep { $_ =~ $cpat } @files;
    if (%$opts) {
	foreach my $opt (split //, 'rwxoRWXOzsfdlpSugkTB') {
	    if ($opts->{$opt}) {
		eval '@files= grep { -'.$opt.' $_ } @files';
	    }
	}
    }
    shift @re;
    if (@re) {
	foreach (@files) {
	    if (-d $_) {
		push @results, _glob($level, $_, 0, $opts, @re);
	    }
	}
	return @results;
    } else {
	push @results, @files;
	return @results;
    }
}

sub glob {
    my( $self, $pattern, $dir) = @_;

    return () unless $pattern;
    return $pattern if index($pattern,'*')==-1 and
      index($pattern,'?')==-1 and
	index($pattern,'~')==-1 and
	  substr($pattern,0,1) ne '[';

    my @result;
    if( !$dir) {
	$dir=$ENV{PWD};
    } else {
	$dir=abs_path($self, $dir) unless file_name_is_absolute($dir);
    }
    return unless $dir;

    # Expand ~
    if ($pattern eq '~') {
	return $ENV{HOME};
    } elsif (substr($pattern,0,1) eq '~') {
	$pattern=~ s|^\~/|$ENV{HOME}/|;
	$pattern=~ s|^\~([^/]+)|&get_home_dir($self, $1)|e;
    }

    return $pattern if index($pattern,'*')==-1 and
      index($pattern,'?')==-1 and
	substr($pattern,0,1) ne '[';

    my $opts={};
    my @re= ();
    if (substr($pattern,0,1) eq '[') {
	if ($pattern=~ /^\[(.+)\(([a-zA-Z]*)\)\]$/) {
	    $pattern=$1;
	    my $optstring=$2;
	    foreach (split //, $optstring) {
		$opts->{$_}= 1;
	    }
	} else {
	    $pattern= substr($pattern,1,-1);
	}
	@re= split /\//, $pattern;
    } else {
	$pattern= _escape($pattern);
	$pattern=~ s/\*/.*/g;
	$pattern=~ s/\?/./g;
	@re= split /\//, $pattern;
    }
    return _glob( 0, $dir, 0, $opts, @re );
}

sub files_ending_with {
    my ($psh, $base, $suffix)= @_;
    opendir( DIR, $base) || return ();
    my @result= grep { substr($_,-length($suffix)) eq $suffix } readdir(DIR);
    closedir( DIR);
    return @result;
}

############################################################################
##
## Misc. Accessors
##
############################################################################

sub fe {
    return shift()->{frontend};
}


############################################################################
##
## Options System
##
############################################################################

my %env_option= qw( cdpath 1 fignore 1 histsize 1 ignoreeof 1 ps1 1
		     psh2 1 path 1);

sub set_option {
    my $self= shift;
    my $option= lc(shift());
    my @value= @_;
    return unless $option;
    return unless @value;
    my $val;
    if ($env_option{$option}) {
	if (@value>1 or (ref $value[0] and ref $value[0] eq 'ARRAY')) {
	    if (ref $value[0]) {
		@value= @{$value[0]};
	    }
	    if ($self->{option}{array_exports} and
		$self->{option}{array_exports}{$option}) {
		$val= join($self->{option}{array_exports}{$option},@value);
	    } else {
		$val= $value[0];
	    }
	} else {
	    $val= $value[0];
	}
	$ENV{uc($option)}= $val;
    } else {
	if (@value>1) {
	    $val= \@value;
	} else {
	    $val= $value[0];
	}
	$self->{option}{$option}= $val;
    }
}

sub get_option {
    my $self= shift;
    my $option= lc(shift());
    my $val;
    if ($env_option{$option}) {
	$val= $ENV{uc($option)};
	if ($self->{option}{array_exports} and
	    $self->{option}{array_exports}{$option}) {
	    $val= [split($self->{option}{array_exports}{$option}, $val)];
	}
    } else {
	$val=$self->{option}{$option};
    }
    if (defined $val) {
	if (wantarray()) {
	    if (ref $val and ref $val eq 'ARRAY') {
		return @{$val};
	    } elsif ( ref $val and ref $val eq 'HASH') {
		return %{$val};
	    }
	    return $val;
	} else {
	    return $val;
	}
    }
    return undef;
}

sub has_option {
    my $self= shift;
    my $option= lc(shift());
    return 1 if exists $self->{option}{$option} or
	($env_option{$option} and $ENV{uc($option)});
    return 0;
}

sub del_option {
    my $self= shift;
    my $option= lc(shift());
    if ($env_option{$option}) {
	delete $ENV{uc($option)};
    } else {
	delete $self->{option}{$option};
    }
}

############################################################################
##
## Built-Ins
##
############################################################################

{
    my %builtin_aliases= (
			  '.' => 'source',
			  'options' => 'option',
			 );
    sub is_builtin {
	my ($self, $com)= @_;
	$com= $builtin_aliases{$com} if $builtin_aliases{$com};
	return $com if $self->{builtin}{$com};
	return 0;
    }

    sub build_builtin_list {
	my $self= shift;
	$self->{builtin}= {};
	my $unshift= '';
	foreach my $tmp (@INC) {
	    my $tmpdir= catdir_fast( $tmp, 'Psh2', 'Builtins');
	    if (-r $tmpdir) {
		my @files= $self->files_ending_with($tmpdir,'.pm');
		foreach (@files) {
		    my $fname= catfile_fast($tmpdir,$_);
		    s/\.pm$//;
		    $_= lc($_);
		    $self->{builtin}{$_}= $fname;
		}
		$unshift= $tmp;
	    }
	}
	unshift @INC, $unshift;
    }
}

############################################################################
##
## Jobs
##
############################################################################

{
    my @order= ();
    my %list= ();
    my $current_job=0;

    sub start_job {
	my $self =shift;
	my $array= shift;
	my $fgflag= shift @$array;

	my $visline= '';
	my ($read, $chainout, $chainin, $pgrp_leader);
	my $tmplen= @$array- 1;
	my @visline= ();
	my @pids= ();
	my $success;
	for (my $i=0; $i<@$array; $i++) {
	    # [ $strategy, $how, $options, $words, $line, $opt ]
	    my ($strategy, $how, $options, $words, $text, $opt)= @{$array->[$i]};

	    my $fork= 0;
	    if ($i<$tmplen or !$fgflag or
		$strategy eq 'execute') {
		$fork= 1;
	    }

	    if ($tmplen) {
		($read, $chainout)= POSIX::pipe();
	    }
	    foreach (@$options) {
		if ($_->[0] == Psh2::Parser::T_REDIRECT() and
		    ($_->[1] eq '<&' or $_->[1] eq '>&')) {
		    if ($_->[3] eq 'chainin') {
			$_->[3]= $chainin;
		    } elsif ($_->[3] eq 'chainout') {
			$_->[3]= $chainout;
		    }
		}
	    }

	    my $pid= 0;
	    if ($^O eq 'MSWin32') {
	    } else {
		if ($fork) {
		    ($pid)= $self->fork($array->[$i], $pgrp_leader, $fgflag,
					($i==$tmplen));
		} else {
		    ($success)= $self->execute($array->[$i]);
		}
	    }
	    if (!$i and !$pgrp_leader and $pid) {
		$pgrp_leader= $pid;
	    }
	    if ($i<$tmplen and $tmplen) {
		POSIX::close($chainout);
		$chainin= $read;
	    }
	    push @visline, $text;
	    push @pids, $pid if $pid;
	}
	if (@pids) {
	    my $job;
	    my $visline= join('|',@visline);
	    if ($^O eq 'MSWin32') {
	    } else {
		$job= Psh2::Unix::Job->new( pid => $pgrp_leader,
					    pids => \@pids,
					    desc => $visline,
					    psh  => $self,);
		foreach (@pids) {
		    $list{$_}= $job;
		}
		push @order, $job;
		$current_job= $#order;
		if ($fgflag) {
		    $success= $job->wait_for_finish();
		} elsif ($self->{interactive}) {
		    my $visindex= @order;
		    my $verb= $self->gt('background');
		    $self->print("[$visindex] \u$verb $pgrp_leader $visline\n");
		}
	    }
	}
	return $success;
    }

    sub delete_job {
	my $self= shift;
	my ($pid) = @_;

	my $job= $list{$pid};
	return unless defined $job;

	delete $list{$pid};
	my $i;
	for ($i=0; $i <= $#order; $i++) {
	    last if( $order[$i]==$job);
	}

	splice( @order, $i, 1);
    }

    sub get_current_job {
	return $list{$current_job};
    }

    sub set_current_job {
	my $self= shift;
	$current_job= shift();
    }

    sub job_exists {
	my $self= shift;
	my $pid= shift;
	return exists $list{$pid};
    }

    sub get_job {
	my $self= shift;
	my $pid= shift;
	return $list{$pid};
    }

    sub list_jobs {
	return wantarray?@order:\@order;
    }

    sub find_job {
	my $self= shift;
	my $job_to_start= shift;

	return $order[$job_to_start] if defined( $job_to_start);

	for (my $i = $#order; $i >= 0; $i--) {
	    my $job = $order[$i];
	    if (!$job->{running}) {
		return $job;
	    }
	}
	return undef;
    }


    sub find_last_with_name {
	my ($self, $name, $runningflag) = @_;
	my $i= $#order;
	while (--$i and $i>-1) {
	    my $job= $order[$i];
	    next if $runningflag and $job->{running};
	    my $desc= $job->{desc};
	    next unless $desc;
	    if ($desc=~ m:([^/\s]+)\s*: ) {
		$desc= $1;
	    } elsif ( $desc=~ m:/([^/\s]+)\s+.*$: ) {
		$desc= $1;
	    } elsif ( $desc=~ m:^([^/\s]+): ) {
		$desc= $1;
	    }
	    if ($desc eq $name) {
		return $job;
	    }
	}
	return undef;
    }

    sub get_job_number {
	my ($self, $pid)= @_;

	for ( my $i=0; $i<=$#order; $i++) {
	    return $i+1 if( $order[$i]->{pid}==$pid);
	}
	return -1;
    }
}

############################################################################
##
## Functions
##
############################################################################

sub add_function {
    my ($self, $name, $coderef, $data)= @_;
    $self->{function}{$name}= [ $name, $coderef];
}

sub delete_function {
    my ($self, $name)= @_;
    delete $self->{function}{$name};
}

1;
