Write-Host "Iniciando compilación de EN RUTA YA!..." -ForegroundColor Magenta

flutter build apk --release

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error fatal: La compilación falló. Revisa el código arriba." -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "¡Compilación completada con éxito!" -ForegroundColor Green

if (Test-Path "build\app\outputs\flutter-apk\app-release.apk") {
    Copy-Item "build\app\outputs\flutter-apk\app-release.apk" -Destination "..\EN_RUTA_YA.apk" -Force
    Write-Host "El archivo APK renombrado se encuentra en la raíz del proyecto como: EN_RUTA_YA.apk" -ForegroundColor Magenta
} else {
    Write-Host "No se encontró el APK generado." -ForegroundColor Red
}
