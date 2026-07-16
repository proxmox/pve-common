TESTS = \
	schema_comparison_test.test				\
	schema_isolated_test.test				\


all:

.PHONY: check
check: $(TESTS)

%.test: %.pl
	perl $<
