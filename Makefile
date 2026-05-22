CC = x86_64-w64-mingw32-gcc
CFLAGS = -O2
LDFLAGS = -luser32
TARGET = codcoldwar-ime-fixer.exe

$(TARGET): codcoldwar-ime-fixer.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

.PHONY: clean
clean:
	rm -f $(TARGET)
