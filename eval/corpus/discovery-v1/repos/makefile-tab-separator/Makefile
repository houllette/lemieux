SOURCES := src/q1.csv src/q2.csv

.PHONY: all clean

all: dist/report.txt

dist/report.txt: $(SOURCES)
    mkdir -p dist
    cat $(SOURCES) | sort > $@

clean:
	rm -rf dist
