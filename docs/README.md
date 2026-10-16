# Scripts de proxies y GIF

Version instalada: `2026.10.16.1`.

## Inicio rapido

En la raiz solo se usa `INICIAR-PROXY-Y-GIFS.cmd`. Al abrirlo aparece un menu para:

1. Procesar todos los proyectos y camaras.
2. Ejecutar solamente una camara.
3. Generar solamente los GIFs.
4. Verificar integridad sin renderizar.
5. Ejecutar el diagnostico de instalacion.
6. Descargar la version mas reciente desde GitHub.
7. Abrir las herramientas adicionales.
8. Organizar las grabaciones nuevas en la carpeta de proyecto de su dia.
9. Ver que le falta a cada proyecto, sin modificar nada.

Para una sola camara, selecciona la opcion 2 y pega la ruta exacta de su carpeta, por ejemplo `100GOPRO`, `CAM_001`, `100QOOCAM` o una ruta de red `\\servidor\carpeta`.

## Estructura identificable

- `00-SISTEMA`: menu, orquestador, diagnostico y actualizacion.
- `01-CAMARAS`: scripts con prefijo `CAM-01` a `CAM-09`.
- `02-GIFS`: scripts con prefijo `GIF`.
- `03-HERRAMIENTAS`: utilidades con prefijo `TOOL`.
- `04-PREMIERE`: scripts para Adobe Premiere con prefijo `PPRO`.
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

## DJI OSMO: proxy VR180 rapido

Ademas del proxy de la lente izquierda y de la vista dual, `CAM-05` crea por cada `.LRF` un proxy con la misma proyeccion que el exportado SBS 8K, en `CAM_001\Proxy DJI OSMO VR180`. Lo obtiene estirando las dos lentes del LRF con `ffmpeg v360`, sin abrir el `.OSV` ni esperar el exportado.

- Se llama igual que el exportado mas `_Proxy` (`CAM_..._D_SBS.mp4` -> `CAM_..._D_SBS_Proxy.mp4`), que es el nombre que Premiere empareja.
- Sale a 2048x1024 y 25 fps, con un fotograma clave por segundo y el color crudo de la camara.
- El angulo de lente (`VR_FOV=187`) se ajusto comparando contra un exportado real; en los bordes puede diferir un poco del SBS.

## Organizar grabaciones y ver pendientes

`TOOL-06-ORGANIZAR-ORIGENES` lleva cada grabacion a la carpeta de proyecto `NNN - Titulo` de su dia. Nunca borra ni sobrescribe: solo mueve dentro del mismo disco y deja un registro en `logs` para deshacer con `-Deshacer`. Tiene tres accesos de doble clic en `03-HERRAMIENTAS`:

- `TOOL-06-1-ANALIZAR.bat`: muestra que moveria y a donde, sin tocar nada.
- `TOOL-06-2-MOVER-CON-CONFIRMACION.bat`: muestra el plan con los nombres de los archivos y pregunta antes de mover.
- `TOOL-06-3-AUTOMATICO.bat`: mueve sin preguntar.

El reloj del microfono TX02 va adelantado; por eso sus archivos se fechan restando `-MicTxOffsetHoras` (13 por defecto). Si se corrige el reloj del microfono, ese valor debe pasar a 0.

`TOOL-07-ESTADO-PROYECTOS` solo lee: lista por proyecto y camara los exportados, proxies y finales que faltan.

## Scripts para Premiere

Se ejecutan dentro de Premiere, sobre la secuencia activa. Conviene usarlos sobre una copia de la secuencia.

- `PPRO-01-CORTAR-AUDIO-POR-SRT.jsx`: en una pista de audio duplicada, conserva solo lo que cae dentro de los intervalos de un SRT.
- `PPRO-02-CERRAR-HUECOS-SIN-VIDEO.jsx`: busca los tramos donde ninguna pista tiene video y le pide a Premiere que los extraiga, del ultimo al primero y sin preguntar. Premiere corre todas las pistas a la vez, tambien las de subtitulos, que un script no puede leer ni mover. Antes de cada extraccion calcula donde debe quedar cada clip de video y audio y despues lo comprueba; si no coincide, deshace ese paso y se detiene.
- `PPRO-03-DIAGNOSTICO-API.jsx`: no modifica nada; lista las funciones que esa version de Premiere ofrece a los scripts.

Cada uno deja su informe junto al script. `pruebas\simular-cerrar-huecos.js` prueba `PPRO-02` fuera de Premiere con `node`.

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

La evidencia visual y la lista exacta de ajustes estan en `docs\QOOCAM-SETTINGS-VERIFICADOS.md`.

## Diagnostico sin render

Desde el menu principal usa la opcion 5. Desde PowerShell tambien puedes ejecutar:

```powershell
& 'C:\ScriptsProxies\tools\Test-Scripts.ps1' -Root 'C:\ScriptsProxies'
```
