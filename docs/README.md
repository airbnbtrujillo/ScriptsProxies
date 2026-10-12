# Scripts de proxies y GIF

Version instalada: `2026.10.11.1`.

## Inicio rapido

En la raiz solo se usa `INICIAR-PROXY-Y-GIFS.cmd`. Al abrirlo aparece un menu para:

1. Procesar todos los proyectos y camaras.
2. Ejecutar solamente una camara.
3. Generar solamente los GIFs.
4. Verificar integridad sin renderizar.
5. Ejecutar el diagnostico de instalacion.
6. Descargar la version mas reciente desde GitHub.

Para una sola camara, selecciona la opcion 2 y pega la ruta exacta de su carpeta, por ejemplo `100GOPRO`, `CAM_001`, `100QOOCAM` o una ruta de red `\\servidor\carpeta`.

## Estructura identificable

- `00-SISTEMA`: menu, orquestador, diagnostico y actualizacion.
- `01-CAMARAS`: scripts con prefijo `CAM-01` a `CAM-09`.
- `02-GIFS`: scripts con prefijo `GIF`.
- `03-HERRAMIENTAS`: utilidades con prefijo `TOOL`.
- `config`: manifiesto y configuracion local.
- `tools`: motores internos de diagnostico y actualizacion.
- `archive`: respaldos recuperables de actualizaciones.
- `logs`: reportes de diagnostico.

El modo de una sola camara copia unicamente el script seleccionado a la carpeta indicada y lo ejecuta ahi. No revisa ni procesa las demas camaras. Las rutas UNC y las unidades de red siguen admitidas mediante `pushd` y operaciones con rutas literales.

## Flujo automatico QOOCAM

Para cada proyecto con carpeta `100QOOCAM`, el procesamiento completo ahora ejecuta una sola cadena:

1. Busca todos los MP4 originales que estan directamente dentro de `100QOOCAM`.
2. Renderiza solamente los faltantes o modificados en `100QOOCAM\KDOutput` usando `180 3D Normal`, importacion Single, Anti-Shake, 7680x3840, H.265 y bitrate High.
3. Ejecuta el flujo de proxies sobre `KDOutput`; los proxies individuales y el final estable que ya existen no se repiten.

Los directorios `KDOutput`, `Proxies`, `Right25` y `_HISTORICO` nunca se vuelven a tomar como originales. El manifiesto `KDOutput\qcam_batch_manifest.json` guarda la huella de cada original y permite continuar despues de una interrupcion sin volver a renderizar lo ya verificado.

Si un original previamente procesado cambia conservando el mismo nombre, el render anterior se mueve de forma recuperable a `100QOOCAM\_HISTORICO`, se genera de nuevo y la comprobacion de integridad aparta sus proxies derivados antes de reconstruirlos. Una salida que ya existe pero nunca fue registrada no se sobrescribe automaticamente.

Para migrar trabajos anteriores, una salida sin manifiesto se adopta automaticamente solo cuando `ffprobe` confirma video HEVC 7680x3840, duracion valida y audio estereo. Si no supera esa verificacion, el proceso se detiene sin sobrescribirla.

La configuracion de QooCam controla temporalmente el raton y requiere una sesion de Windows desbloqueada. Conviene iniciar este flujo durante las horas libres. El indicador visible avisa cuando esta configurando y cuando QooCam ya esta renderizando sin hacer clics.

## Integridad y recuperacion automatica

Antes de `Procesar todo`, el sistema compara el inventario actual de originales con el inventario de la ejecucion anterior. Tambien abre con `ffprobe` los originales, proxies y finales para detectar videos ilegibles o truncados, archivos `.partial.mp4`, cantidades diferentes y duraciones finales incompatibles con sus partes.

Los originales son siempre de solo lectura: el sistema nunca los borra, mueve, renombra ni modifica.

- Si cambio un original, se prepara solamente su camara.
- Si se retiraron todos los originales de una camara registrada, sus resultados anteriores se apartan y la camara queda bloqueada hasta que vuelvan los originales correctos.
- Si fallo un proxy individual, se apartan ese proxy y el final para reconstruirlos.
- Si solo fallo el final, se conservan los proxies intermedios y se reconstruye el final.
- Si un original esta ilegible, la reparacion de esa camara se bloquea y conserva sus resultados hasta que el original sea revisado.
- Los proxies apartados no se borran: quedan en `_HISTORICO\fecha_hora` dentro de su misma carpeta de proxies.
- El final anterior queda en la subcarpeta `FINAL` de ese mismo historico.
- El inventario compartido queda en `.proxy-integrity` dentro del proyecto, por lo que funciona aunque otra computadora vea el disco con una letra diferente.

La opcion 4 del menu ejecuta una revision informativa sin renderizar ni apartar archivos. La opcion 1 realiza esta revision automaticamente y prepara las reparaciones antes del flujo normal.

## TECHE rapido

TECHE utiliza directamente `TechePrev.mp4`, que ya tiene la misma proporcion que `TecheMain.mp4`, sin decodificar el archivo 8K. No altera la velocidad del contenido:

- Si las duraciones coinciden, normaliza rapidamente el preview.
- Si el preview es mas largo, recorta y normaliza el final.
- Si es mas corto, agrega negro al final y recorta exactamente a la duracion del Main, incluso cuando el preview tiene marcas internas defectuosas.
- Todos los proxies quedan con timestamps, FPS y audio uniformes para una union segura.
- El final se une sin recodificar todos los clips nuevamente y se valida contra la suma de sus partes antes de instalarse.

El reporte `TECHE TimeSync Report.csv` indica para cada clip si fue copia directa, recorte o agregado de negro. El mapa `TECHE Main-Proxy Map.csv` conserva la correspondencia exacta entre el main y su proxy para Premiere.

## Instalar en otra computadora

```powershell
git clone https://github.com/airbnbtrujillo/ScriptsProxies.git C:\ScriptsProxies
cd C:\ScriptsProxies
.\INICIAR-PROXY-Y-GIFS.cmd
```

Para actualizar posteriormente, abre el mismo lanzador y elige la opcion 6, o usa:

```powershell
git -C C:\ScriptsProxies pull --ff-only
```

El actualizador valida la descarga y guarda los archivos reemplazados o retirados en `archive\updates`.

QooCam Studio se detecta automaticamente en sus ubicaciones habituales. Si otra computadora lo tiene instalado en una ruta diferente, define `QooCamStudioExe` en `config\settings.json`. Si la interfaz cambia por version o escala de pantalla, corrige el codigo fuente incluido en `tools\QooCamAutomation`, prueba en esa computadora y publica la correccion por Git para que ambas usen el mismo programa.

## Diagnostico sin render

Desde el menu principal usa la opcion 5. Desde PowerShell tambien puedes ejecutar:

```powershell
& 'C:\ScriptsProxies\tools\Test-Scripts.ps1' -Root 'C:\ScriptsProxies'
```
