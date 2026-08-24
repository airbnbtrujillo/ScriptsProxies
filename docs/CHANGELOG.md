# Cambios

## 2026.08.24.1

- TECHE prueba el codificador NVIDIA con una codificacion real y usa CPU si la GPU no funciona.
- Los errores del corrector temporal quedan guardados junto al proxy como `*.timesync-error.log`.
- Un clip TECHE defectuoso ya no detiene los clips siguientes del mismo proyecto.
- El script conserva los proxies validos, reemplaza parciales al reintentar y devuelve un codigo de error verificable.
- El render final usa parametros compatibles tanto con NVIDIA como con CPU.
- El diagnostico comprueba NVENC con una codificacion minima real para validar cada computadora.

## 2026.08.23.3

- Se dejo un unico lanzador visible en la raiz.
- Se organizaron los archivos en Sistema, Camaras, GIFs y Herramientas.
- Se numeraron los scripts de camara de `CAM-01` a `CAM-09`.
- Se agrego ejecucion directa de una sola camara sin revisar las demas.
- Se agrego ejecucion individual de GIFs desde el menu.
- Se corrigieron todas las invocaciones internas para las nuevas rutas.
- Se mantuvo el uso de rutas locales, UNC y unidades de red.
- El actualizador ahora archiva y retira los nombres antiguos de la raiz.

## 2026.08.23.2

- Se configuro GitHub como origen de actualizaciones.
- Se agregaron instrucciones de instalacion y pull para otra computadora.

## 2026.08.23.1

- Se corrigio el caracter accidental al inicio de `PROXY y GIFS.ps1`.
- Se redujo el intervalo de comprobacion del orquestador de 200 a 15 segundos.
- Se agrego preflight automatico antes de procesar proyectos.
- Se agregaron diagnostico independiente, manifiesto y version instalada.
- Se agrego actualizador seguro para Git o carpeta sincronizada.
- Los respaldos sueltos se archivan fuera de la raiz activa.
- Se mantienen todos los nombres activos para no romper el flujo existente.
