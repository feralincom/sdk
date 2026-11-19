' Task ve uygulama yüzü dosyalarının sözdizimi denetimi (brs). Task iş parçacığı ve roUrlTransfer burada çalıştırılmaz; cihaz ister.
sub main()
    env = Feralin_DeviceEnv("1.0.0")
    if Feralin__IsString(env.uuid()) and Len(env.nowIso()) = 24 then print "PARSE ok" else print "PARSE FAIL"
end sub
