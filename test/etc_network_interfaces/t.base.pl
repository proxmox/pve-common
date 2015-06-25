my $wanted = load('base');

# parse the empty file
r('');
expect $wanted;

# idempotency
# save, re-parse, and re-check
r(w());
expect $wanted;

1;
