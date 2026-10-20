.PHONY: all seed test
all: seed
	bash scripts/run_all.sh
seed:
	python3 scripts/gen_seed.py
test: all
