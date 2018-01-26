#!/usr/bin/perl
use strict;
use warnings;
use autodie;
use feature qw(say);

use Cwd;
use Getopt::Std;
use Pod::Usage;
use XML::LibXML;
use XML::Tidy;

getopts("hBbMmwRc:i:e:t:n:a:r:", \my %args);

# Exit with help text if requested or required -i switch is missing
pod2usage(-exitval => 0, -verbose => 2, -noperldoc => 1) if exists $args{h};
pod2usage(2) if !exists $args{i};

# Resolve jobs directory
my $jenkins_home = exists $args{p} ? $args{p} : getcwd();
my $jobs_dir = "$jenkins_home/jobs";
pod2usage(2) unless -d $jobs_dir;

# Explode job pattern arguments
my @includes = exists $args{i} ? split(',', $args{i}) : ();
my @excludes = exists $args{e} ? split(',', $args{e}) : ();
pod2usage(2) if !scalar @includes && !scalar @excludes;

# Aggregate all existing jobs
my @jobs;
opendir(my $dirh, $jobs_dir);
while (readdir $dirh) {
   next if /^\./;
   for my $pattern (@excludes) {
      next if $_ eq $pattern;
   }
   for my $pattern (@includes) {
      if ($_ eq $pattern || $pattern eq "*") {
         push @jobs, $_;
         next;
      }
   }
}
closedir($dirh);

# Main loop: iterate through all config.xml files and apply changes
for my $job (@jobs) {
   # Load the XML DOM into memory
   my $config_file = "$jobs_dir/$job/config.xml";
   my $DOM = XML::LibXML->load_xml(location => $config_file);
   my $RootNode = $DOM->documentElement();

   # Generate the build discarder property element set
   if (exists $args{B} || exists $args{b}) {
      if (add_build_discarder($DOM, exists $args{B})) {
         say "$job: Registered build discarder property";
         save($DOM, $config_file);
      }
      else {
         say "WARNING: Cannot add build discarder property to $job!";
      }
      next;
   }

   # Generate the default permission matrix settings
   if (exists $args{M} || exists $args{m}) {
      if (add_auth_perms($DOM, exists $args{M})) {
         say "$job: Registered default auth perms";
         save($DOM, $config_file);
      }
      else {
         say "WARNING: Cannot set default auth perms to $job!";
      }
      next;
   }

   # Generate the default scan compiler warnings settings
   if (exists $args{w}) {
      if (add_scan_warnings($DOM)) {
         say "$job: Registered scan compiler warnings settings";
         save($DOM, $config_file);
      }
      else {
         say "WARNING: Cannot set scan compiler warnings settings to $job!";
      }
      next;
   }

   # Convert common elements for a prod version of the config
   if (exists $args{c}) {
      if (prod_conversion($DOM)) {
         say "$job: Prod conversion successful";
         save($DOM, $config_file);
      }
      else {
         say "WARNING: Failed prod conversion for $job!";
      }
      next;
   }

   # Construct default release build settings
   if (exists $args{R}) {
      if (add_release($DOM)) {
         say "$job: Release build settings registered";
         save($DOM, $config_file);
      }
      else {
         say "WARNING: Cannot set release build settings for $job!";
      }
      next;
   }

   my $pair = $args{t} // $args{n} // $args{a} // $args{r};
   my ($name, $value) = split(',', $pair);
   if (!defined $args{r} && !defined $value) {
      say "WARNING: Invalid node/text specification for $job.";
      next;
   }

   my ($Node) = $RootNode->findnodes(".//$name");
   if (!defined $Node) {
      say "WARNING: Node $name not found for $job; skipping.";
      next;
   }

   # Process a text replacement
   if (exists $args{t}) {
      # For non-empty text element
      if (my $Text = $Node->firstChild) {
         $Text->setData($value);
      }
      # For empty element, append text
      else {
         $Node->appendText($value);
      }
      say "$job: $name -> $value";
   }
   # Process new child node entry
   elsif (exists $args{n}) {
      my $Child = $DOM->createElement($value);
      $Node->appendChild($Child);
      say "$job: $name + $value";
   }
   # Process attribute replacement
   elsif (exists $args{a}) {
      my ($attr_name, $attr_val) = split('=', $value);
      if (!defined $attr_val) {
         say "WARNING: Invalid attribute $attr_name for $job.";
         next;
      }
      $Node->{$attr_name} = $attr_val;
      say "$job: $attr_name=\"$attr_val\"";
   }
   # Process node removal
   elsif (exists $args{r}) {
      $Node->unbindNode();
      say "$job: $name removed";
   }
   # Program flow should never reach here; just warn the user
   else {
      say "WARNING: Nothing to do for $job; did you forget a switch?";
      next;
   }

   save($DOM, $config_file);
}

sub save {
   my ($DOM, $config_file) = @_;
   my $Tidy = XML::Tidy->new(xml => $DOM->toString());
   $Tidy->tidy();
   $Tidy->write($config_file);
}

sub add_build_discarder {
   my ($DOM, $force) = @_;
   my $RootNode = $DOM->documentElement();
   my ($Properties) = $RootNode->findnodes(".//properties");

   # Sanity check: job config must have the properties element
   if (!defined $Properties) {
      return 0;
   }

   # Abort if the element already exists
   if ($Properties->findnodes("/jenkins.model.BuildDiscarderProperty")) {
      return 1;
   }
   # If the element exists, abort or clobber based on the force option
   my $tag = "jenkins.model.BuildDiscarderProperty";
   my ($BDP) = $Properties->findnodes(".//$tag");
   if (defined $BDP) {
      return 1 unless $force;
      $BDP->unbindNode();
   }

   # Assemble all the elements for this set and append to DOM
   $BDP = $DOM->createElement("jenkins.model.BuildDiscarderProperty");
   my $Strategy = $DOM->createElement("strategy");
   $Strategy->{"class"} = "hudson.tasks.LogRotator";

   # Use 4 different Node variables to avoid reference clobbering
   my $Node1 = $DOM->createElement("daysToKeep");
   $Node1->appendText("5");
   $Strategy->appendChild($Node1);

   my $Node2 = $DOM->createElement("numToKeep");
   $Node2->appendText("5");
   $Strategy->appendChild($Node2);

   my $Node3 = $DOM->createElement("artifactDaysToKeep");
   $Node3->appendText("5");
   $Strategy->appendChild($Node3);

   my $Node4 = $DOM->createElement("artifactNumToKeep");
   $Node4->appendText("5");
   $Strategy->appendChild($Node4);

   $BDP->appendChild($Strategy);
   $Properties->appendChild($BDP);

   return 1;
}

sub add_auth_perms {
   my ($DOM, $force) = @_;
   my $RootNode = $DOM->documentElement();
   my ($Properties) = $RootNode->findnodes(".//properties");

   # Sanity check: job config must have the properties element
   if (!defined $Properties) {
      return 0;
   }

   # If the element exists, abort or clobber based on the force option
   my $tag = "hudson.security.AuthorizationMatrixProperty";
   my ($AuthMatrix) = $Properties->findnodes(".//$tag");
   if (defined $AuthMatrix) {
      return 1 unless $force;
      $AuthMatrix->unbindNode();
   }

   # Assemble all the elements for this set and append to DOM
   $AuthMatrix = $DOM->createElement($tag);
   my $Strategy = $DOM->createElement("inheritanceStrategy");
   $Strategy->{"class"} =
      "org.jenkinsci.plugins.matrixauth.inheritance.InheritParentStrategy";
   $AuthMatrix->appendChild($Strategy);

   my $Node = $DOM->createElement("permission");
   $Node->appendText("hudson.model.Item.Build:authenticated");
   $AuthMatrix->appendChild($Node);

   $Node = $DOM->createElement("permission");
   $Node->appendText("hudson.model.Item.Read:authenticated");
   $AuthMatrix->appendChild($Node);

   $Node = $DOM->createElement("permission");
   $Node->appendText("hudson.model.Item.Workspace:authenticated");
   $AuthMatrix->appendChild($Node);

   $Node = $DOM->createElement("permission");
   $Node->appendText(
      "hudson.plugins.release.ReleaseWrapper.Release:authenticated"
   );
   $AuthMatrix->appendChild($Node);

   $Node = $DOM->createElement("permission");
   $Node->appendText("hudson.scm.SCM.Tag:authenticated");
   $AuthMatrix->appendChild($Node);

   $Properties->appendChild($AuthMatrix);

   return 1;
}

sub add_scan_warnings {
   my $DOM = shift;
   my $RootNode = $DOM->documentElement();
   my ($Publishers) = $RootNode->findnodes(".//publishers");
   my $Node;

   # Sanity check: job config must have the publishers element
   if (!defined $Publishers) {
      return 0;
   }

   my $tag = "hudson.plugins.warnings.WarningsPublisher";
   return 1 if $RootNode->findnodes(".//publishers/$tag");
   my $Warnings = $DOM->createElement($tag);
   $Warnings->{"plugin"} = 'warnings@4.64';

   my @nodes = (
      "healthy",
      "unHealthy",
      ["thresholdLimit", "low"],
      ["pluginName", "[WARNINGS] "],
      "defaultEncoding",
      ["canRunOnFailed", "false"],
      ["usePreviousBuildAsReference", "false"],
      ["useDeltaValues", "false"]
   );
   for (@nodes) {
      my ($node, $value) = ref $_ eq "ARRAY" ? @$_ : $_;
      $Node = $DOM->createElement($node);
      $Node->appendText($value) if defined $value;
      $Warnings->appendChild($Node);
   }

   my $Thresholds = $DOM->createElement("thresholds");
   $Thresholds->{"plugin"} = 'analysis-core@1.93';

   $Node = $DOM->createElement("unstableTotalAll");
   $Node->appendText("0");
   $Thresholds->appendChild($Node);

   @nodes = (
      "unstableTotalHigh",
      "unstableTotalNormal",
      "unstableTotalLow",
      "unstableNewAll",
      "unstableNewHigh",
      "unstableNewNormal",
      "unstableNewLow",
      "failedTotalAll",
      "failedTotalHigh",
      "failedTotalNormal",
      "failedTotalLow",
      "failedNewAll",
      "failedNewHigh",
      "failedNewNormal",
      "failedNewLow"
   );
   for (@nodes) {
      $Node = $DOM->createElement($_);
      $Thresholds->appendChild($Node);
   }

   $Warnings->appendChild($Thresholds);

   $Node = $DOM->createElement("shouldDetectModules");
   $Node->appendText("false");
   $Warnings->appendChild($Node);

   $Node = $DOM->createElement("dontComputeNew");
   $Node->appendText("true");
   $Warnings->appendChild($Node);

   $Node = $DOM->createElement("doNotResolveRelativePaths");
   $Node->appendText("true");
   $Warnings->appendChild($Node);

   @nodes = (
      "includePattern",
      "excludePattern",
      "messagesPattern",
      "categoriesPattern",
      "parserConfigurations"
   );
   for (@nodes) {
      $Node = $DOM->createElement($_);
      $Warnings->appendChild($Node);
   }

   $tag = "hudson.plugins.warnings.ConsoleParser";
   my $Parsers = $DOM->createElement("consoleParsers");
   my $ConsoleParser = $DOM->createElement($tag);
   my $ParserName = $DOM->createElement("parserName");
   $ParserName->appendText("Java Compiler (javac)");
   $ConsoleParser->appendChild($ParserName);
   $Parsers->appendChild($ConsoleParser);

   $Warnings->appendChild($Parsers);
   $Publishers->appendChild($Warnings);

   return 1;
}

sub prod_conversion {
   my $DOM = shift;
   my $RootNode = $DOM->documentElement();

   # Unset the days-to-keep limit
   for ($RootNode->findnodes(".//daysToKeep")) {
      my $Text = $_->firstChild;
      $Text->setData("-1");
   }

   # Change all branch selection filters
   for ($RootNode->findnodes(".//tagsFilter")) {
      my $Text = $_->firstChild;
      $Text->setData("^(?!branches).*");
   }

   # Drop auth matrix
   my $tag = ".//hudson.security.AuthorizationMatrixProperty";
   $_->unbindNode() for $RootNode->findnodes($tag);

   # Disable script trigger
   $_->unbindNode() for $RootNode->findnodes(".//authToken");

   # Eliminate unstable return options for sysout scan
   $_->unbindNode() for $RootNode->findnodes(".//unstableReturn");

   # Switch scan warnings from unstable to failed
   for ($RootNode->findnodes(".//unstableTotalAll")) {
      my $Text = $_->firstChild;
      $Text->setData("");
   }
   $_->appendText("0") for $RootNode->findnodes(".//failedTotalAll");

   # Drop environment selector
   $tag = ".//hudson.model.ChoiceParameterDefinition";
   $_->unbindNode() for $RootNode->findnodes($tag);

   # Drop failing build suspect entry
   $tag = "hudson.plugins.emailext.plugins.recipients.FirstFailingBuild" .
      "SuspectsRecipientProvider";
   $_->unbindNode() for $RootNode->findnodes($tag);

   # Drop unstable trigger for email
   $tag = "hudson.plugins.emailext.plugins.trigger.UnstableTrigger";
   $_->unbindNode() for $RootNode->findnodes($tag);

   1;
}

sub add_release {
   my $DOM = shift;
   my $RootNode = $DOM->documentElement();
   return 1 if $RootNode->findnodes(".//buildWrappers");
   my $Node;

   my $BuildWrappers = $DOM->createElement("buildWrappers");

   # Assemble pre-build
   my $tag = "hudson.plugins.ws__cleanup.PreBuildCleanup";
   my $PreBuildCleanup = $DOM->createElement($tag);
   $PreBuildCleanup->{"plugin"} = 'ws-cleanup@0.34';
   $Node = $DOM->createElement("deleteDirs");
   $Node->appendText("false");
   $PreBuildCleanup->appendChild($Node);
   for (("cleanupParameter", "externalDelete")) {
      $PreBuildCleanup->appendChild($DOM->createElement($_));
   }
   $BuildWrappers->appendChild($PreBuildCleanup);

   # Assemble timestamper
   $tag = "hudson.plugins.timestamper.TimestamperBuildWrapper";
   $Node = $DOM->createElement($tag);
   $Node->{"plugin"} = 'timestamper@1.8.9';
   $BuildWrappers->appendChild($Node);

   # Assemble release wrapper
   $tag = "hudson.plugins.release.ReleaseWrapper";
   my $ReleaseWrapper = $DOM->createElement($tag);
   $ReleaseWrapper->{"plugin"} = 'release@2.9';
   $Node = $DOM->createElement("releaseVersionTemplate");
   $ReleaseWrapper->appendChild($Node);
   $Node = $DOM->createElement("doNotKeepLog");
   $Node->appendText("true");
   $ReleaseWrapper->appendChild($Node);
   $Node = $DOM->createElement("overrideBuildParameters");
   $Node->appendText("false");
   $ReleaseWrapper->appendChild($Node);

   my $ParameterDefinitions = $DOM->createElement("parameterDefinitions");
   $tag = "hudson.scm.listtagsparameter.ListSubversionTagsParameterDefinition";
   ($Node) = $RootNode->findnodes(".//parameterDefinitions/$tag");
   $ParameterDefinitions->appendChild($Node->cloneNode(1));

   my $CPD = $DOM->createElement("hudson.model.ChoiceParameterDefinition");
   $Node = $DOM->createElement("name");
   $Node->appendText("RELEASE_ENVIRONMENT");
   $CPD->appendChild($Node);
   $Node = $DOM->createElement("description");
   $Node->appendText("The environment where the build will be deployed.");
   $CPD->appendChild($Node);
   my $Choices = $DOM->createElement("choices");
   $Choices->{"class"} = 'java.util.Arrays$ArrayList';
   my $A = $DOM->createElement("a");
   $A->{"class"} = "string-array";
   for (("Dev", "Test")) {
      $Node = $DOM->createElement("string");
      $Node->appendText($_);
      $A->appendChild($Node);
   }
   $Choices->appendChild($A);
   $CPD->appendChild($Choices);
   $ParameterDefinitions->appendChild($CPD);
   $ReleaseWrapper->appendChild($ParameterDefinitions);

   my $PBS = $DOM->createElement("preBuildSteps");
   ($Node) = $RootNode->findnodes(".//hudson.tasks.Shell");
   $PBS->appendChild($Node->cloneNode(1));
   $tag = ".//hudson.plugins.warnings.WarningsPublisher";
   ($Node) = $RootNode->findnodes($tag);
   $PBS->appendChild($Node->cloneNode(1));
   $ReleaseWrapper->appendChild($PBS);

   my @nodes = (
      "postBuildSteps",
      "postSuccessfulBuildSteps",
      "postFailedBuildSteps",
      "preMatrixBuildSteps",
      "postSuccessfulMatrixBuildSteps",
      "postFailedMatrixBuildSteps",
      "postMatrixBuildSteps"
   );
   $ReleaseWrapper->appendChild($DOM->createElement($_)) for (@nodes);
   $BuildWrappers->appendChild($ReleaseWrapper);
   $RootNode->appendChild($BuildWrappers);

   1;
}

__END__

=head1 NAME

Jenkins Job Configuration Mass Editor

=head1 SYNOPSIS

jenkconfed.pl [options]

=over

=item -h Display the complete help manual for this script and exit

=item -p Set Jenkins' home path

=item -i Job list to include

=item -e Job list to exclude

=item -t Text replacement

=item -n New node entry

=item -a Attribute assignment

=item -r Remove node from document

=item -b Generate default build discarder property block

=item -B Same as -b, but overwrites if discarder settings already exist

=item -m Generate default authentication permissions matrix settings

=item -M Same as -m, but overwrites if matrix settings already exist

=item -w Generate default scan warnings block

=item -R Construct the default release build settings

=item -c Convert config options for prod usage

=back

=head1 OPTIONS

=over 4

=item B<-h>

Print this manual and exit.

=item B<-p>

Path to Jenkins' home. Defaults to the current working directory.

The script will automatically descend into the jobs directory and parse
all config.xml files according to the options provided.

=item B<-i>

Comma-delimited list of jobs to include for editing. Use "*" to indicate
all jobs. B<Do not use * unless you know what you are doing.>

(The quotes protect against the shell's interpretation of the wildcard.)

=item B<-e>

Comma-delimited list of jobs to exclude from editing. Only applicable
with -i "*".

=item B<-t>

Text replacement switch. Locate the XML element of the first value, and
insert a text value for that tag using the second value.

Example: This option would write <disabled>true</disabled> to the DOM

-t disabled,true

=item B<-n>

New node entry. Locates the XML element of the first value and creates a
new child element for it named after the second value.

Example: This option adds <sample></sample> to a <properties> tag

-n properties,sample

=item B<-a>

Attribute assignment. Writes an attribute value to an element.
Note: attributes should be the complete name/value string.

Example: Set sample tag as <sample attr="true">

-a sample,attr=true

Do B<NOT> quote the attribute for this switch's name/value pair.

=item B<-r>

Remove node. Specify an element to be removed from the DOM. For example, -r
sample would remove the <sample> tag from the document.

=item B<-B>, B<-b>

Generate a default build discarder property block. Unless settings already
exist, a new entry will be registered. Use B<-b> to ensure job configurations
are limiting historical builds on the file system. Use B<-B> to discard any
existing discarder settings and write the new default. If both switches are
present, B<-B> always takes precedence.

=item B<-M>, B<-m>

Generate a default authentication permissions matrix. Use this switch to ensure
non-production job entries are visible to underprivileged authenticated users.
With B<-m>, the existing settings will not be changed. Use B<-M> to discard any
existing matrix settings and write the new default. If both switches are
present, B<-M> always takes precedence.

=item B<-w>

Generate a default scan warnings block. This block creates an entry that will
enforce the build status as unstable if javac produces any warnings.

=item B<-R>

Constructs the default release build settings. This routine will consume
existing SVN, compiler warning, and shell  settings from the config file when
assembling the release build options.

=item B<-c>

Convert for prod usage. This option will convert the following common
predictable options for the desired prod usage:

=over 8

=item Unset the days-to-keep limit for builds

=item Change branch filter to omit branches rather than trunk

=item Disable the auth matrix to hide the config from underprivileged users

=item Disable trigger for external script control

=item Promote System.out detector to fail the build

=item Promote linter to fail the build

=back

=back

=head1 DESCRIPTION

This script modifies an arbitrary number of Jenkins job config.xml files.
It can add a child node, edit a node's text, or edit an attribute value.
Only B<single operations> may be selected per call. Extraneous switches will be
B<ignored silently>.

Disambiguation of tag selection is supported by partial XPath specification. For
example, name is not a unique element and may be uniquely identified by
prefixing it with the name of its parent element e.g. 'parentElement/name' would
match the name element that is the child of parentElement only, and not the
child name of element otherElement.

=cut

# vim: set ts=3 sw=3 tw=80 et :
