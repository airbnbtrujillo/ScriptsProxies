# Scripts de proxies y GIF

Version instalada: `2026.08.24.1`.

## Inicio rapido

En la raiz solo se usa `INICIAR-PROXY-Y-GIFS.cmd`. Al abrirlo aparece un menu para:

1. Procesar todos los proyectos y camaras.
2. Ejecutar solamente una camara.
3. Generar solamente los GIFs.
4. Ejecutar el diagnostico sin renderizar.
5. Descargar la version mas reciente desde GitHub.

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

## Instalar en otra computadora

```powershell
git clone https://github.com/airbnbtrujillo/ScriptsProxies.git C:\ScriptsProxies
cd C:\ScriptsProxies
.\INICIAR-PROXY-Y-GIFS.cmd
```

Para actualizar posteriormente, abre el mismo lanzador y elige la opcion 5, o usa:

```powershell
git -C C:\ScriptsProxies pull --ff-only
```

El actualizador valida la descarga y guarda los archivos reemplazados o retirados en `archive\updates`.

## Diagnostico sin render

Desde el menu principal usa la opcion 4. Desde PowerShell tambien puedes ejecutar:

```powershell
& 'C:\ScriptsProxies\tools\Test-Scripts.ps1' -Root 'C:\ScriptsProxies'
```
