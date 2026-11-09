# DownloadUltron

Consola de PowerShell para descargar lotes de audio y video en Windows 10 y 11 de 64 bits (x64). Acepta enlaces sueltos o un TXT, muestra el progreso por enlace y permite reintentar los fallidos.

## Empezar

Clona el repositorio o usa **Code → Download ZIP** y descomprime la carpeta. Desde PowerShell 5.1 o posterior, ejecuta lo siguiente dentro de la carpeta.

```powershell
.\DownloadUltron.ps1
```

Al iniciar el primer lote, el programa descarga yt-dlp, FFmpeg, ffprobe y Deno en `tools\` y verifica las sumas SHA-256. La preparación requiere internet y funciona sin permisos de administrador. También puedes preparar las herramientas de antemano.

```powershell
.\scripts\Get-Tools.ps1
.\DownloadUltron.ps1 -Diagnostico
```

Si Windows bloquea los scripts del ZIP, revisa el código y desbloquea solo los dos archivos del proyecto antes de ejecutarlos.

```powershell
Unblock-File -LiteralPath '.\DownloadUltron.ps1', '.\scripts\Get-Tools.ps1'
```

## Usar la consola

1. Pulsa **1** y pega la ruta del TXT, o pulsa **2** y pega los enlaces separados por líneas o comas. Termina el pegado con Enter en una línea vacía. También puedes pegar una URL en el prompt principal.
2. Pulsa **3** para indicar la carpeta de destino. Con **4** eliges MP3, MP4 o M4A. MP3 y MP4 incluyen opciones de calidad automática máxima y mínima.
3. Pulsa **7** para iniciar. El panel distingue enlaces procesados, archivos listos y errores. **X** detiene el lote y **?** muestra los demás atajos.

Con **6** puedes elegir un perfil de Brave, Chrome, Edge o Firefox, un archivo Netscape o la opción **Sin cookies**. Los perfiles y archivos de cookies no se guardan en los ajustes. Si falla el acceso a la sesión, el panel muestra el diagnóstico y **E** abre el detalle.

El motor registra los IDs completados por formato en el destino y guarda los fallidos en `_errores_*.txt`. Usa **R** para reintentar los fallidos de la sesión, o vuelve a cargar el TXT más tarde.

## Ejecutar un lote desde PowerShell

```powershell
.\DownloadUltron.ps1 -Lote '.\enlaces.txt' -Formato mp3_max -Ejecutar
```

Puedes usar `-Urls` con enlaces separados por comas, `-Destino` para elegir la carpeta y `-SinActualizar` para omitir la comprobación de esa ejecución. El programa consulta el canal estable de yt-dlp al iniciar lotes, como máximo una vez cada 24 horas. Con `-Actualizar` puedes forzar la consulta.

## Licencia

El código de DownloadUltron se publica bajo la [licencia MIT](LICENSE). Las herramientas descargadas conservan sus propias licencias. [yt-dlp](https://github.com/yt-dlp/yt-dlp#license), [FFmpeg](https://ffmpeg.org/legal.html), [compilaciones de Gyan](https://www.gyan.dev/ffmpeg/builds/) y [Deno](https://github.com/denoland/deno/blob/main/LICENSE.md).
