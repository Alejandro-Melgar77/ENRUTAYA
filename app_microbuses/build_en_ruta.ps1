Write-Host "Iniciando compilación de EN RUTA YA!..." -ForegroundColor Purple
flutter build apk --release

$apkPath = "build\app\outputs\flutter-apk\app-release.apk"
$destPath = "..\EN_RUTA_YA.apk"

if (Test-Path $apkPath) {
    Copy-Item -Path $apkPath -Destination $destPath -Force
    Write-Host "¡Compilación completada con éxito!" -ForegroundColor Green
    Write-Host "El archivo APK renombrado se encuentra en la raíz del proyecto como: EN_RUTA_YA.apk" -ForegroundColor Green
} else {
    Write-Host "Error: No se encontró el APK compilado. Revisa los mensajes de error de Flutter arriba." -ForegroundColor Red
}
