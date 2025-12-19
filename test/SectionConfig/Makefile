TESTS = \
	schema_comparison_test.pl				\


all:

.PHONY: check
check: $(TESTS)
	for TEST in $(TESTS); do perl $$TEST; done

