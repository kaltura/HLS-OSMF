all: check
	@echo "-------- AES Decryption Library --------"

	@echo && echo "Compiling SWC"
	"$(FLASCC)/usr/bin/g++" $(BASE_CFLAGS) -O4 aes.c as3api.cpp main.cpp -emit-swc=com.kaltura.crypto.DecryptUtil -o aes-decrypt.swc

include Makefile.common

clean:
	rm -f *.swf *.swc *.bc *.exe
