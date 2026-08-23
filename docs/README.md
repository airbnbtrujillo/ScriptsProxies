# Scripts de proxies y GIF

Version instalada: `2026.08.23.2`.

## Punto de entrada

`PROXY y GIFS.ps1` sigue siendo el orquestador principal. Los nombres de los scripts activos permanecen en la raiz para conservar compatibilidad con proyectos y copias antiguas.

Lanzadores recomendados:

- `INICIAR-PROXY-Y-GIFS.cmd`: ejecuta el flujo normal.
- `DIAGNOSTICO-SCRIPTS.cmd`: revisa archivos, sintaxis y herramientas sin renderizar.
- `ACTUALIZAR-SCRIPTS.cmd`: instala una version validada desde el origen configurado y guarda respaldo.

## Estructura

- `config/`: manifiesto, version y origen de actualizaciones.
- `tools/`: diagnostico y actualizador.
- `docs/`: documentacion.
- `archive/`: respaldos manuales y copias previas a actualizaciones.
- `logs/`: reportes de diagnostico y ejecucion.
- `OLD/`: versiones historicas anteriores.

## Nube

La ejecucion siempre se realiza desde la copia local estable `F:\Scripts`. No se recomienda ejecutar directamente desde una carpeta que se este sincronizando mientras FFmpeg trabaja.

Configura uno de estos campos en `config/settings.json`:

- `GitRepository`: URL de un repositorio Git privado. Es la opcion recomendada porque conserva historial y permite volver a una version anterior.
- `CloudMirror`: ruta local sincronizada por OneDrive, Dropbox o Google Drive que contenga una copia completa de esta estructura.

El actualizador descarga o lee primero en una ubicacion separada, ejecuta el diagnostico y solo entonces copia los archivos. Antes de reemplazar algo crea un respaldo en `archive/updates/`.

## Debugging sin render

Desde PowerShell:

```powershell
& 'F:\Scripts\PROXY y GIFS.ps1' -PreflightOnly
```

El resultado completo queda en `logs/diagnostico_*.json` cuando se usa `DIAGNOSTICO-SCRIPTS.cmd`.

## Instalar en otra computadora

Con Git instalado, abre PowerShell y ejecuta:

```powershell
git clone https://github.com/airbnbtrujillo/ScriptsProxies.git C:\ScriptsProxies
cd C:\ScriptsProxies
.\DIAGNOSTICO-SCRIPTS.cmd
```

Puedes elegir otra carpeta. Los scripts resuelven sus dependencias desde su propia ubicacion.

Para recibir cambios posteriores, usa una de estas opciones:

```powershell
git -C C:\ScriptsProxies pull --ff-only
```

O ejecuta `ACTUALIZAR-SCRIPTS.cmd`. El actualizador valida primero la descarga y guarda los archivos anteriores en `archive\updates\`.
