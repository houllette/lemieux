all: build/app.txt

build/app.txt: src/main.txt src/lib.txt
	mkdir -p build
	cat src/main.txt src/lib.txt > build/app.txt

test:
	sh test/run.sh

clean:
	rm -rf build
