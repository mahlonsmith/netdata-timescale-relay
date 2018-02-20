
FILES = netdata_tsrelay.nim

default: release

debug: ${FILES}
	nim --assertions:on --nimcache:.cache c ${FILES}

development: ${FILES}
	# can use gdb with this...
	nim --debugInfo --linedir:on -d:testing -d:nimTypeNames --nimcache:.cache c ${FILES}

debugger: ${FILES}
	nim --debugger:on --nimcache:.cache c ${FILES}

release: ${FILES}
	nim -d:release --opt:speed --parallelBuild:0 --nimcache:.cache c ${FILES}

docs:
	nim doc ${FILES}
	#nim buildIndex ${FILES}

clean:
	cat .hgignore | xargs rm -rf

