Secret Santa Randomizer and Mailer
==================================

`secretsanta.pl` is a script used to set up a secret santa gift exchange.  It
reads a list of participants from a YAML file, matches them randomly, and
optionally sends an email to each participant informing them of their match.

Setup
=====

This program doesn't need to be installed, however it does have some perl
dependencies.  You should have a local perl 5 installation from your system,
which should include CPAN.  If you don't have `cpan` installed and configured,
you can configure a local CPAN installation in your home directory:

```
cpan App::cpanminus
```

After installing cpanminus, you will need to re-source your `~/.bashrc`.

Once you have `cpanm` installed, just run:

```
cpanm --installdeps .
```

After that completes, you should be able to run `secretsanta.pl -h`.

Usage
=====

See the full help by running `secretsanta.pl --man`.
