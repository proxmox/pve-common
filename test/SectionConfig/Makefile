TESTS = \
	schema_comparison_test.test				\
	schema_isolated_test.test				\
	schema_extra_args_test.test				\


all:

.PHONY: check
check: $(TESTS)

%.test: %.pl
	perl $<
