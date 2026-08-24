# Cambios

## 2026.08.24.4

- Se declara y aplica una proteccion estricta: ningun original puede ser movido por el reparador de integridad.
- Los proxies reemplazados se guardan en `_HISTORICO` dentro de su misma carpeta de proxies.
- Los finales anteriores se conservan en `FINAL` dentro del historico correspondiente.
- El verificador ignora los historicos para que no se confundan con proxies vigentes.

## 2026.08.24.3

- TECHE usa directamente el preview 1920x960 completo y deja de recortar media imagen.
- Ya no estira ni acelera el contenido para corregir diferencias de duracion.
- Las coincidencias se copian, los sobrantes se recortan sin recodificar y los faltantes se completan con negro al final.
- El final TECHE se concatena por stream copy y evita un segundo render completo por el rotulo.
- El modo CPU usa `ultrafast` y el modo NVIDIA usa el preset rapido `p1`.
- El reporte temporal indica el metodo aplicado y la cantidad de negro agregada.

## 2026.08.24.2

- Se agrego verificacion comun de integridad para VUZE, QOOCAM, GoPro, Gear 360, DJI OSMO, Insta EVO, Tarsier, TECHE e Insta GO 3.
- Se guarda un inventario compartido de rutas, tamanos y fechas de originales para detectar archivos movidos, agregados, eliminados o modificados.
- Si desaparecen todos los originales de una camara ya registrada, sus resultados obsoletos se archivan y esa camara queda bloqueada de forma segura.
- Se detectan proxies y finales corruptos, parciales, cantidades incoherentes y duraciones finales incompatibles.
- La reparacion automatica afecta solamente la camara necesaria y conserva los demas resultados.
- Los archivos dudosos se trasladan a un archivo recuperable en vez de eliminarse definitivamente.
- El flujo completo ejecuta esta comprobacion antes de decidir que camaras debe saltar.

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
