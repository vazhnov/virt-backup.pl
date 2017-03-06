#!/usr/bin/perl -w

# AUTHOR
#   Daniel Berteaud <daniel@firewall-services.com>
#
# COPYRIGHT
#   Copyright (C) 2009-2011  Daniel Berteaud
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA



# This script allows you to backup Virtual Machines managed by libvirt.
# It has only be tested with KVM based VM
# This script will dump (or mount as a set of chunks):
# * each block devices
# * optionnally the memory (if --state flag is given)
# * the XML description of the VM

# These files are writen in a temporary backup dir. Everything is done
# in order to minimize donwtime of the guest. For example, it takes
# a snapshot of the block devices (if backed with LVM) so the guest is
# just paused for a couple of seconds. Once this is done, the guest is
# resumed, and the script starts to dump the snapshot.

# Once a backup is finished, you'll have several files in the backup
# directory. Let's take an example with a VM called my_vm which has
# two virtual disks: hda and hdb. You have passed the --state flag:
# * my_vm.lock: lock file to prevent another backup to run at the same time
# * my_vm.xml: this file is the XML description of the VM (for libvirt configuraiton)
# * my_vm_hda.img: this file is an image of the hda drive of the guest
# * my_vm_hdb.img: this file is an image of the hdb drive of the guest
# * my_vm.state: this is a dump of the memory (result of virsh save my_vm my_vm.state)

# This script was made to be ran with BackupPC pre/post commands.
# In pre-backup, you dump everything (or mount as a set of chunks), then, backuppc backups,
# compress, pools etc... the dumped file. Eventually, when the backup is finished
# The script is called with the --action=cleanup flag, which cleanups everything.
# (remove the temporary files, umount the fuse mount points if any etc.)

# Some examples:
#
# Backup the VM named mail01 and devsrv. Also dump the memory.
# Exclude any virtual disk attached as vdb or hdb and on the fly
# compress the dumped disks (uses gzip by default)
# virt-backup.pl --dump --vm=mail01,devsrv --state --exclude=vdb,hdb --compress

# Remove all the files related to mail01 VM in the backup directory
# virt-backup.pl --cleanup --vm=mail01

# Backup devsrv, use 10G for LVM snapshots (if available), do not dump the memory
# (the guest will just be paused while we take a snapshot)
# Keep the lock file present after the dump
# virt-backup.pl --dump --vm=devsrv --snapsize=10G --keep-lock

# Backup devsrv, and disable LVM snapshots
# virt-backup.pl --dump --vm=devsrv --no-snapshot

# Backup mail01, and enable debug (verbose output)
# virt-backup.pl --dump --vm=mail01 --debug

# Don't dump, but mount as a set of chunks the disks of vm mail01
#  virt-backup.pl --action=chunkmount --vm=mail01

# The idea here is to expose the big blocks/files which represent the VM disks
# as small chunks (default is 256kB), then, you can use your favorite backup script/software
# to backup /var/lib/libvirt/backup/vm_name/ where you want
# This lets you create incremential backups of VM disks, which can save
# a lot of space, a lot of bandwidth, and will also be much more efficient
# with rsync based backup scripts (because rsync doesn't handle huge files very well
# but if very efficient with a lot of small files)
# The cleanup routine (--cleanup or --action=cleanup) will unmount all
# the chunkfs mount points





### TODO:
# - If all the disks cannot be snapshoted, the VM should be locked so it cannot be accidentally started
#   during a backup
# - Add snapshot (LVM) support for image based disk ? (should we detect the mount moint, and block device
#    of the storage or let the user specify it with a --logical ?)
# - Additionnal check that the vm is available after a restore (via $dom->get_info->{status}, ping ?)
# - Check if compression utilies are available
# - Support per vm excludes in one run



### CHANGES
# * 31/07/2011
# - Add new option to mount images as chunked files using chunkfs
# - Use 512k chunk size for LVM snapshots which should reduce performance penalty during backups
#
# * 26/03/2010
# - Initial packaged version

use XML::Simple;
use Sys::Virt;
use Getopt::Long;
use File::Which qw(which);

# Set umask
umask(022);

# Some constant

our %opts = ();
our @vms = ();
our @excludes = ();
our @disks = ();

# Sets some defaults values

# What to run. The default action is to dump
$opts{action} = 'dump';
# Where backups will be stored. This directory must already exists
$opts{backupdir} = '/var/lib/libvirt/backup';
# Size of LVM snapshots (which will be used to backup VM with minimum downtown
# if the VM store data directly on a LV)
$opts{snapsize} = '5G';
# If we should also dump the VM state (dump the mémory, equivalent of virsh save)
$opts{state} = 0;
# Debug
$opts{debug} = 0;
# Let the lock file present after the dump is finisehd
$opts{keeplock} = 0;
# Should we try to create LVM snapshots during the dump ?
$opts{snapshot} = 1;
# Libvirt URI to connect to
$opts{connect} = "qemu:///system";
# Compression used with the dump action (the compression is done on the fly)
$opts{compress} = 'none';
# lvcreate path
$opts{lvcreate} = which('lvcreate') . ' -c 512' || die "Can't find lvcreate\n";
# lvremove path
$opts{lvremove} = which('lvremove') || die "Can't find lvremove\n";
# chunkfs path
$opts{chunkfs} = '/usr/bin/chunkfs';
# Size of chunks to use with chunkfs or or blocks with dd in bytes (default to 256kB)
$opts{blocksize} = '262144';
# nice may be used to reduce CPU priority of compression processes
$opts{nice} = 'nice -n 19';
# ionice may be used to reduce disk access priority of dump/chunkfs processes
# which can be quite I/O intensive. This only works if your storage
# uses the CFQ scheduler (which is the default on EL)
$opts{ionice} = 'ionice -c 2 -n 7';

$opts{livebackup} = 1;
$opts{wasrunning} = 1;

# get command line arguments
GetOptions(
    "debug"        => \$opts{debug},
    "date"         => \$opts{date},
    "keep-lock"    => \$opts{keeplock},
    "state"        => \$opts{state},
    "snapsize=s"   => \$opts{snapsize},
    "backupdir=s"  => \$opts{backupdir},
    "vm=s"         => \@vms,
    "action=s"     => \$opts{action},
    "cleanup"      => \$opts{cleanup},
    "dump"         => \$opts{dump},
    "unlock"       => \$opts{unlock},
    "connect=s"    => \$opts{connect},
    "snapshot!"    => \$opts{snapshot},
    "compress:s"   => \$opts{compress},
    "exclude=s"    => \@excludes,
    "blocksize=s" => \$opts{blocksize},
    "help"         => \$opts{help}
);


# Set compression settings
if ($opts{compress} eq 'lzop'){
    $opts{compext} = ".lzo";
    $opts{compcmd} = "lzop -c";
}
elsif ($opts{compress} eq 'bzip2'){
    $opts{compext} = ".bz2";
    $opts{compcmd} = "bzip2 -c";
}
elsif ($opts{compress} eq 'pbzip2'){
    $opts{compext} = ".bz2";
    $opts{compcmd} = "pbzip2 -c";
}
elsif ($opts{compress} eq 'xz'){
    $opts{compext} = ".xz";
    $opts{compcmd} = "xz -c";
}
elsif ($opts{compress} eq 'lzip'){
    $opts{compext} = ".lz";
    $opts{compcmd} = "lzip -c";
}
elsif ($opts{compress} eq 'plzip'){
    $opts{compext} = ".lz";
    $opts{compcmd} = "plzip -c";
}
# Default is gzip
elsif (($opts{compress} eq 'gzip') || ($opts{compress} eq '')) {
    $opts{compext} = ".gz";
    $opts{compcmd} = "gzip -c";
}
else{
    $opts{compext} = "";
    $opts{compcmd} = "cat";
}

# Date option
my $date = '';
if ($opts{date}){
    $date = '_' . `date +%F_%H-%M-%S`;
    chomp $date;
}

# Allow comma separated multi-argument
@vms = split(/,/,join(',',@vms));
@excludes = split(/,/,join(',',@excludes));

# Backward compatible with --dump --cleanup --unlock
$opts{action} = 'dump' if ($opts{dump});
$opts{action} = 'cleanup' if ($opts{cleanup});
$opts{action} = 'unlock' if ($opts{unlock});

# Stop here if we have no vm
# Or the help flag is present
if ((!@vms) || ($opts{help})){
    usage();
    exit 1;
}

if (! -d $opts{backupdir} ){
    print "$opts{backupdir} is not a valid directory\n";
    exit 1;
}

# Connect to libvirt
print "\n\nConnecting to libvirt daemon using $opts{connect} as URI\n" if ($opts{debug});
our $libvirt = Sys::Virt->new( uri => $opts{connect} ) ||
    die "Error connecting to libvirt on URI: $opts{connect}";

print "\n" if ($opts{debug});

foreach our $vm (@vms){
    # Create a new object representing the VM
    print "Checking $vm status\n\n" if ($opts{debug});
    our $dom = $libvirt->get_domain_by_name($vm) ||
        die "Error opening $vm object";
    our $backupdir = $opts{backupdir}.'/'.$vm;
    if ($opts{action} eq 'cleanup'){
        print "Running cleanup routine for $vm\n\n" if ($opts{debug});
        run_cleanup();
    }
    elsif ($opts{action} eq 'unlock'){
        print "Unlocking $vm\n\n" if ($opts{debug});
        unlock_vm();
    }
    elsif ($opts{action} eq 'dump'){
        print "Running dump routine for $vm\n\n" if ($opts{debug});
        mkdir $backupdir || die $!;
        mkdir $backupdir . '.meta' || die $!;
        run_dump();
    }
    elsif ($opts{action} eq 'chunkmount'){
        print "Running chunkmount routine for $vm\n\n" if ($opts{debug});
        mkdir $backupdir || die $!;
        mkdir $backupdir . '.meta' || die $!;
        run_chunkmount();
    }
    else {
        usage();
        exit 1;
    }
}


############################################################################
##############                FUNCTIONS                 ####################
############################################################################

sub prepare_backup{
    # Create a new XML object
    my $xml = new XML::Simple ();
    my $data = $xml->XMLin( $dom->get_xml_description(), forcearray => ['disk'] );

    # STop here if the lock file is present, another dump might be running
    die "Another backup is running\n" if ( -e "$backupdir.meta/$vm.lock" );

    # Lock VM: Create a lock file so only one dump process can run
    lock_vm();

    # Save the XML description
    save_xml();

    # Save the VM state if it's running and --state is present
    # (else, just suspend the VM)
    $opts{wasrunning} = 0 unless ($dom->is_active());

    if ($opts{wasrunning}){
        if ($opts{state}){
            save_vm_state();
        }
        else{
            suspend_vm();
        }
    }

    # Create a list of disks used by the VM
    foreach $disk (@{$data->{devices}->{disk}}){

        my $source;
        if ($disk->{type} eq 'block'){
            $source = $disk->{source}->{dev};
        }
        elsif ($disk->{type} eq 'file'){
            $source = $disk->{source}->{file};
        }
        else{
            print "\nSkipping $source for vm $vm as its type is $disk->{type}: " .
                " and only block and file are supported\n" if ($opts{debug});
            next;
        }
        my $target = $disk->{target}->{dev};

        # Check if the current disk is not excluded
        if (grep { $_ eq "$target" } @excludes){
            print "\nSkipping $source for vm $vm as it's matching one of the excludes: " .
                join(",",@excludes)."\n\n" if ($opts{debug});
            next;
        }

        # If the device is a disk (and not a cdrom) and the source dev exists
        if (($disk->{device} eq 'disk') && (-e $source)){

            print "\nAnalysing disk $source connected on $vm as $target\n\n" if ($opts{debug});

            # If it's a block device
            if ($disk->{type} eq 'block'){

                my $time = "_".time();
                # Try to snapshot the source if snapshot is enabled
                if ( ($opts{snapshot}) && (create_snapshot($source,$time)) ){
                    print "$source seems to be a valid logical volume (LVM), a snapshot has been taken as " .
                        $source . $time ."\n" if ($opts{debug});
                    $source = $source.$time;
                    push (@disks, {source => $source, target => $target, type => 'snapshot'});
                }
                # Snapshot failed, or disabled: disabling live backups
                else{
                    if ($opts{snapshot}){
                        print "Snapshotting $source has failed (not managed by LVM, or already a snapshot ?)" .
                            ", live backup will be disabled\n" if ($opts{debug}) ;
                    }
                    else{
                        print "Not using LVM snapshots, live backups will be disabled\n" if ($opts{debug});
                    }
                    $opts{livebackup} = 0;
                    push (@disks, {source => $source, target => $target, type => 'block'});
                }
            }
            elsif ($disk->{type} eq 'file'){
                $opts{livebackup} = 0;
                push (@disks, {source => $source, target => $target, type => 'file'});
            }
            print "Adding $source to the list of disks to be backed up\n" if ($opts{debug});
        }
    }

    # Summarize the list of disks to be dumped
    if ($opts{debug}){
        if ($opts{action} eq 'dump'){
            print "\n\nThe following disks will be dumped:\n\n";
            foreach $disk (@disks){
                print "Source: $disk->{source}\tDest: $backupdir/$vm" . '_' . $disk->{target} . $date .
                    ".img$opts{compext}\n";
            }
        }
        elsif($opts{action} eq 'chunkmount'){
            print "\n\nThe following disks will be mounted as chunks:\n\n";
            foreach $disk (@disks){
                print "Source: $disk->{source}\tDest: $backupdir/$vm" . '_' . $disk->{target} . $date;
            }
        }
    }

    # If livebackup is possible (every block device can be snapshotted)
    # we can restore the VM now, in order to minimize the downtime
    if ($opts{livebackup}){
        print "\nWe can run a live backup\n" if ($opts{debug});
        if ($opts{wasrunning}){
            if ($opts{state}){
                restore_vm();
            }
            else{
                resume_vm();
            }
        }
    }
}

sub run_dump{

    # Pause VM, dump state, take snapshots etc..
    prepare_backup();

    # Now it's time to actually dump the disks
    foreach $disk (@disks){

        my $source = $disk->{source};
        my $dest = "$backupdir/$vm" . '_' . $disk->{target} . $date . ".img$opts{compext}";

        print "\nStarting dump of $source to $dest\n\n" if ($opts{debug});
        my $ddcmd = "$opts{ionice} dd if=$source bs=$opts{blocksize} | $opts{nice} $opts{compcmd} > $dest 2>/dev/null";
        unless( system("$ddcmd") == 0 ){
            die "Couldn't dump the block device/file $source to $dest\n";
        }
        # Remove the snapshot if the current dumped disk is a snapshot
        destroy_snapshot($source) if ($disk->{type} eq 'snapshot');
    }

    # If the VM was running before the dump, restore (or resume) it
    if ($opts{wasrunning}){
        if ($opts{state}){
            restore_vm();
        }
        else{
            resume_vm();
        }
    }
    # And remove the lock file, unless the --keep-lock flag is present
    unlock_vm() unless ($opts{keeplock});
}

sub run_chunkmount{
    # Pause VM, dump state, take snapshots etc..
    prepare_backup();

    # Now, lets mount guest images with chunkfs
    foreach $disk (@disks){

        my $source = $disk->{source};
        my $dest = "$backupdir/$vm" . '_' . $disk->{target};
        mkdir $dest || die $!;
        print "\nMounting $source on $dest with chunkfs\n\n" if ($opts{debug});
        my $cmd = "$opts{ionice} $opts{chunkfs} -o fsname=chunkfs-$vm $opts{blocksize} $source $dest 2>/dev/null";
        unless( system("$cmd") == 0 ){
            die "Couldn't mount $source on $dest\n";
        }
    }
}

# Remove the dumps
sub run_cleanup{
    print "\nRemoving backup files\n" if ($opts{debug});
    my $cnt = 0;
    my $meta = 0;
    my $snap = 0;

    # If a state file is present, restore the VM
    if (-e "$backupdir/$vm.state"){
        restore_vm();
    }
    # Else, try to resume it
    else{
        resume_vm();
    }

    if (open MOUNTS, "</proc/mounts"){
        foreach (<MOUNTS>){
            my @info = split(/\s+/, $_);
            next unless ($info[0] eq "chunkfs-$vm");
            print "Found chunkfs mount point: $info[1]\n" if ($opts{debug});
            my $mp = $info[1];
            print "Unmounting chunkfs mount point $mp\n\n" if ($opts{debug});
            die "Couldn't unmount $mp\n" unless (
                system("/bin/umount $mp 2>/dev/null") == 0
            );
            rmdir $mp || die $!;
        }
        close MOUNTS;
    }

    $cnt = unlink <$backupdir/*>;
    if (open SNAPLIST, "<$backupdir.meta/snapshots"){
        foreach (<SNAPLIST>){
            # Destroy snapshot listed here if it exists
            # and only if its name ends with _ and 10 digits
            chomp;
            if ((-e $_) && ($_ =~ m/_\d{10}$/)){
               print "Found $_ in snapshot list, will try to remove it\n" if ($opts{debug});
               destroy_snapshot($_);
               $snap++;
            }
        }
        close SNAPLIST;
    }
    $meta = unlink <$backupdir.meta/*>;
    rmdir "$backupdir/";
    rmdir "$backupdir.meta";
    print "$cnt file(s) removed\n$snap LVM snapshots removed\n$meta metadata files removed\n\n" if $opts{debug};
}


sub usage{
    print "usage:\n$0 --action=[dump|cleanup|chunkmount|unlock] --vm=vm1[,vm2,vm3] [--debug] [--exclude=hda,hdb] [--compress] ".
        "[--state] [--no-snapshot] [--snapsize=<size>] [--backupdir=/path/to/dir] [--connect=<URI>] ".
        "[--keep-lock] [--bs=<block size>]\n" .
    "\n\n" .
    "\t--action: What action the script will run. Valid actions are\n\n" .
    "\t\t- dump: Run the dump routine (dump disk image to temp dir, pausing the VM if needed). It's the default action\n" .
    "\t\t- cleanup: Run the cleanup routine, cleaning up the backup dir\n" .
    "\t\t- chunkmount: Mount each device as a chunkfs mount point directly in the backup dir\n" .
    "\t\t- unlock: just remove the lock file, but don't cleanup the backup dir\n\n" .
    "\t--vm=name: The VM you want to work on (as known by libvirt). You can backup several VMs in one shot " .
        "if you separate them with comma, or with multiple --vm argument. You have to use the name of the domain, ".
        "ID and UUID are not supported at the moment\n\n" .
    "\n\nOther options:\n\n" .
    "\t--state: Cleaner way to take backups. If this flag is present, the script will save the current state of " .
        "the VM (if running) instead of just suspending it. With this you should be able to restore the VM at " .
        "the exact state it was when the backup started. The reason this flag is optional is that some guests " .
        "crash after the restoration, especially when using the kvm-clock. Test this functionality with" .
        "your environnement before using this flag in production\n\n" .
    "\t--no-snapshot: Do not attempt to use LVM snapshots. If not present, the script will try to take a snapshot " .
        "of each disk of type 'block'. If all disks can be snapshotted, the VM is resumed, or restored (depending " .
        "on the --state flag) immediately after the snapshots have been taken, resulting in almost no downtime. " .
        "This is called a \"live backup\" in this script" .
        "If at least one disk cannot be snapshotted, the VM is suspended (or stopped) for the time the disks are " .
        "dumped into the backup dir. That's why you should use a fast support for the backup dir (fast disks, RAID0 " .
        "or RAID10)\n\n" .
    "\t--snapsize=<snapsize>: The amount of space to use for snapshots. Use the same format as -L option of lvcreate. " .
        "eg: --snapsize=15G. Default is 5G\n\n" .
    "\t--compress[=[gzip|bzip2|pbzip2|lzop|xz|lzip|plzip|pigz]]: On the fly compress the disks images during the dump. If you " .
        "don't specify a compression algo, gzip will be used.\n\n" .
    "\t--exclude=hda,hdb: Prevent the disks listed from being dumped. The names are from the VM perspective, as " .
        "configured in livirt as the target element. It can be useful for example if you want to dump the system " .
        "disk of a VM, but not the data one which can be backed up separately, at the files level.\n\n" .
    "\t--backupdir=/path/to/backup: Use an alternate backup dir. The directory must exist and be writable. " .
        "The default is /var/lib/libvirt/backup\n\n" .
    "\t--connect=<URI>: URI to connect to libvirt daemon (to suspend, resume, save, restore VM etc...). " .
        "The default is qemu:///system.\n\n" .
    "\t--date: Add date and time to filename.\n\n" .
    "\t--keep-lock: Let the lock file stay present. This prevents another " .
        "dump to run while a third party backup software (BackupPC for example) saves the dumped files.\n\n";
}

# Save a running VM, if it's running
sub save_vm_state{
    if ($dom->is_active()){
        print "$vm is running, saving state....\n" if ($opts{debug});
        $dom->save("$backupdir/$vm.state");
        print "$vm state saved as $backupdir/$vm.state\n" if ($opts{debug});
    }
    else{
        print "$vm is not running, nothing to do\n" if ($opts{debug});
    }
}

# Restore the state of a VM
sub restore_vm{
    if (! $dom->is_active()){
        if (-e "$backupdir/$vm.state"){
            print "\nTrying to restore $vm from $backupdir/$vm.state\n" if ($opts{debug});
            $libvirt->restore_domain("$backupdir/$vm.state");
            print "Waiting for restoration to complete\n" if ($opts{debug});
            my $i = 0;
            while ((!$dom->is_active()) && ($i < 120)){
                sleep(5);
                $i = $i+5;
            }
            print "Timeout while trying to restore $vm, aborting\n"
                if (($i > 120) && ($opts{debug}));
        }
        else{
            print "\nRestoration impossible, $backupdir/$vm.state is missing\n" if ($opts{debug});
        }
    }
    else{
        print "\nCannot start domain restoration, $vm is running (maybe already restored after a live backup ?)\n"
            if ($opts{debug});
    }
}

# Suspend a VM
sub suspend_vm(){
    if ($dom->is_active()){
        print "$vm is running, suspending\n" if ($opts{debug});
        $dom->suspend();
        print "$vm now suspended\n" if ($opts{debug});
    }
    else{
        print "$vm is not running, nothing to do\n" if ($opts{debug});
    }
}

# Resume a VM if it's paused
sub resume_vm(){
    if ($dom->get_info->{state} == Sys::Virt::Domain::STATE_PAUSED){
        print "$vm is suspended, resuming\n" if ($opts{debug});
        $dom->resume();
        print "$vm now resumed\n" if ($opts{debug});
    }
    else{
        print "$vm is not suspended, nothing to do\n" if ($opts{debug});
    }
}

# Dump the domain description as XML
sub save_xml{
    print "\nSaving XML description for $vm to $backupdir/$vm.xml\n" if ($opts{debug});
    open(XML, ">$backupdir/$vm" . ".xml") || die $!;
    print XML $dom->get_xml_description();
    close XML;
}

# Create an LVM snapshot
# Pass the original logical volume and the suffix
# to be added to the snapshot name as arguments
sub create_snapshot{
    my ($blk,$suffix) = @_;
    my $ret = 0;
    print "Running: $opts{lvcreate} -p r -s -n " . $blk . $suffix .
        " -L $opts{snapsize} $blk > /dev/null 2>&1\n" if $opts{debug};
    if ( system("$opts{lvcreate} -s -n " . $blk . $suffix .
        " -L $opts{snapsize} $blk > /dev/null 2>&1") == 0 ) {
        $ret = 1;
        open SNAPLIST, ">>$backupdir.meta/snapshots" or die "Error, couldn't open snapshot list file\n";
        print SNAPLIST $blk.$suffix ."\n";
        close SNAPLIST;
    }
    return $ret;
}

# Remove an LVM snapshot
sub destroy_snapshot{
    my $ret = 0;
    my ($snap) = @_;
    print "Removing snapshot $snap\n" if $opts{debug};
    if (system ("$opts{lvremove} -f $snap > /dev/null 2>&1") == 0 ){
        $ret = 1;
    }
    return $ret;
}

# Lock a VM backup dir
# Just creates an empty lock file
sub lock_vm{
    print "Locking $vm\n" if $opts{debug};
    open ( LOCK, ">$backupdir.meta/$vm.lock" ) || die $!;
    print LOCK "";
    close LOCK;
}

# Unlock the VM backup dir
# Just removes the lock file
sub unlock_vm{
    print "Removing lock file for $vm\n\n" if $opts{debug};
    unlink <$backupdir.meta/$vm.lock>;
}

