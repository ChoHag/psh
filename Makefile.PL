use ExtUtils::MakeMaker;

my $pms= {};
my $pods= {};
my $sb_depends='';
my $sb_files='';
my $sb_winfiles='';
my @sb_winfiles=();

foreach (qw(bang perl brace built_in perlfunc executable eval)) {
    my $ucase= ucfirst($_);
    my $tmp='lib/Psh/Strategy/'.$ucase.'.pm';
    $sb_depends.=$tmp." \\\n\t";
    $sb_files.=$tmp.' ';
    push @sb_winfiles, "lib\\Psh\\Strategy\\$ucase.pm";
}
$sb_winfiles= join(' +',@sb_winfiles);
$sb_depends= substr($sb_depends,0,-4);

sub MY::postamble {
	# to copy share files after installation
	my $tmp="

install ::
	\$(PERL) postinstall.pl \$(SITEPREFIX) \$(PREFIX)


lib/Psh/StrategyBunch.pm : $sb_depends
";
	if ($^O eq 'MSWin32') {
	    $tmp.="	copy $sb_winfiles lib\\Psh\\StrategyBunch.pm

";
	} else {
	    $tmp.="	echo \"## do not modify - autogenerated ##\" > lib/Psh/StrategyBunch.pm
	cat $sb_files >> lib/Psh/StrategyBunch.pm

";
	}
	return $tmp;
}

open( FILE, "< MANIFEST");
while( <FILE>)
{
	chomp;
	next if $_ !~ /.pm$/;
	my $dest= $_;
	$dest=~ s/^lib/\$(INST_LIBDIR)/;
	$pms->{$_}=$dest;
}
$pms->{'lib/Psh/StrategyBunch.pm'}='$(INST_LIBDIR)/Psh/StrategyBunch.pm';

close(FILE);

chdir 'doc';

my @tmp= glob('*.pod');
foreach (@tmp) {
	my $source= 'doc/'.$_;
	s/\.pod$//;
	my $dest= '$(INST_MAN1DIR)/'.$_.'.$(MAN1EXT)';
	$pods->{$source}=$dest;
}
chdir '..';


WriteMakefile (
	NAME         => 'psh',
	VERSION_FROM => 'lib/Psh.pm',
	AUTHOR       => 'Gregor N. Purdy, Sr. (gnp@acm.org)',
	ABSTRACT     => 'Perl Shell',
	EXE_FILES    => [ qw(psh) ],
    PREREQ_PM    => {
					 'Cwd'   => '0',
					 'File::Spec' => '0',
					},
	MAN1PODS     => $pods,
    PM           => $pms,
#	PM_FILTER    => 'grep -v \\"^\\#\\"',  # remove comments on install
	dist         => { COMPRESS => 'gzip -9f', SUFFIX => 'gz' },
        clean        => { FILES => "psh-*.tar.gz lib/Psh/StrategyBunch.pm" },
);

eval {
	require Term::ReadLine;
	require Term::ReadLine::Gnu;
};
if ($@) {
	eval {
		require Term::ReadLine::Perl;
	};
	if ($@) {
		print "We suggest you install Term::ReadLine::Gnu or Term::ReadLine::Perl to make psh more useful!\n";
	}
}

eval {
	require BSD::Resource;
};
if ($@) {
	print "The 'ulimit' command in psh will not work, unless you install BSD::Resource.\n";
}

