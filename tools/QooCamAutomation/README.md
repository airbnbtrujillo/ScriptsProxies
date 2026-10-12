# Automatizador QooCam

Este componente convierte los MP4 originales de `100QOOCAM` en renders VR180 dentro de `KDOutput` con estos ajustes fijos:

- `180 3D Normal` (no Reverse)
- importacion `Single`
- Anti-Shake para cada video
- 7680x3840, MP4 H.265, bitrate High y audio estereo

El archivo `qcam_batch_manifest.json` dentro de `KDOutput` registra el tamano y la fecha de cada original. Si el render verificado ya existe y el original no cambio, no vuelve a procesarlo.

El orquestador lo llama automaticamente antes de `CAM-02-QOOCAM-PROXY.bat`. Durante la configuracion de QooCam, Windows debe estar desbloqueado y no se debe usar el raton. Cuando el indicador diga que el render ya comenzo, el automatizador deja de hacer clics.

## Otra computadora

Primero instala QooCam Studio. El programa busca estas ubicaciones automaticamente:

- `C:\Program Files (x86)\QooCamStudio\QooCamStudio.exe`
- `C:\Program Files\QooCamStudio\QooCamStudio.exe`
- variantes dentro de la carpeta `Kandao`

Si QooCam esta en otro lugar, agrega esta propiedad a `config\settings.json`:

```json
"QooCamStudioExe": "D:\\Aplicaciones\\QooCamStudio\\QooCamStudio.exe"
```

Las correcciones de interfaz especificas de otra PC se realizan en `qcam_batch_automator.py`, se recompila el `.exe` y se publican por Git para mantener una sola version compatible.

Antes de recompilar, ejecuta `python -m unittest test_batch_inputs.py`. Para generar el ejecutable, instala las dependencias del fuente y ejecuta `pyinstaller --noconfirm --clean QooCam_VR180_Batch_AntiShake.spec` dentro de esta carpeta.
