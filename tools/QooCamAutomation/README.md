# Automatizador QooCam

Esta carpeta contiene el **fuente** y el ejecutable que controla QooCam Studio para convertir los originales de `100QOOCAM` en renders VR180 dentro de `KDOutput`. El archivo que se ejecuta es `QooCam_VR180_Batch_AntiShake.exe`; el archivo que se debe leer o modificar es `qcam_batch_automator.py`.

## Mapa rápido del flujo

```text
100QOOCAM (MP4 originales)
        │  lectura: nunca mueve ni borra originales
        ▼
qcam_batch_automator.py ── controla QooCam Studio ──► KDOutput (MP4 8K VR180)
        │                                               │
        │ manifiesto: qcam_batch_manifest.json           ▼
        └── omite originales sin cambios          CAM-02-QOOCAM-PROXY.bat
                                                     ├─ Proxies
                                                     └─ Right25 / final de Premiere
```

Los ajustes de QooCam son fijos:

- `180 3D Normal` (no Reverse)
- importacion `Single`
- Anti-Shake para cada video
- 7680x3840, MP4 H.265, bitrate High y audio estereo

## Cómo lee y decide qué procesar

`discover_jobs()` es la función de entrada. Lee las carpetas indicadas y busca MP4; no modifica ningún original. Para evitar bucles, descarta automáticamente `KDOutput`, `Proxies`, `Right25`, `_HISTORICO`, el directorio temporal de pruebas y los nombres que ya parecen salida (`_Output`, `_Reframe` o `_Proxy`).

Cada original se compara con `KDOutput/qcam_batch_manifest.json`, que guarda nombre, tamaño y fecha. Si el original no cambió y su salida ya pasa la validación (HEVC 7680x3840, duración y audio), se omite. Si falta, está dañada o el original cambió, se programa solo ese render.

El automatizador **no procesa proxies**: su única salida es el render 8K de QooCam en `KDOutput`. El BAT de cámara posterior crea los archivos ligeros para Premiere.

El orquestador lo llama automaticamente antes de `CAM-02-QOOCAM-PROXY.bat`. Durante la configuracion de QooCam, Windows debe estar desbloqueado y no se debe usar el raton. Cuando el indicador diga que el render ya comenzo, el automatizador deja de hacer clics.

## Adaptarlo a otra computadora o pantalla

No hay una tabla de coordenadas que debas recalibrar según la resolución. El programa hace lo siguiente para resistir otra pantalla:

1. Activa conciencia de DPI físico para que Windows no cambie píxeles al usar escalado de 125 %, 150 % o varios monitores.
2. Lleva la ventana de QooCam al frente y `prepare_editor()` la centra en una zona de trabajo estable (hasta 1600×1000).
3. Localiza controles por nombre o `auto_id` de UI Automation.
4. Cuando QooCam/Qt no expone un botón en UI Automation, calcula el clic desde el rectángulo real de ese control; no usa un punto absoluto de pantalla.

Por eso, primero prueba sin cambiar nada. Durante la configuración no uses el ratón; una vez que el indicador diga que el render comenzó, ya no hace clics.

Si falla en una versión distinta de QooCam, revisa antes de editar:

- Log: `%LOCALAPPDATA%\QooCamBatchAntiShake\automator.log`
- Capturas de los menús: `%LOCALAPPDATA%\QooCamBatchAntiShake\screenshots`
- Mensaje del paso exacto que falló.

Normalmente se adapta un selector de control, un `auto_id` o el texto de una opción en `qcam_batch_automator.py`; no se agregan coordenadas fijas. El modo `180 3D Normal` fue comprobado con QooCam Studio 3.3.0.18 y tiene capturas `01-menu`, `02-switch` y `03-normal-seleccionado` para comparar el menú.

## Otra computadora

Primero instala QooCam Studio. El programa busca estas ubicaciones automaticamente:

- `C:\Program Files (x86)\QooCamStudio\QooCamStudio.exe`
- `C:\Program Files\QooCamStudio\QooCamStudio.exe`
- variantes dentro de la carpeta `Kandao`

Si QooCam esta en otro lugar, agrega esta propiedad a `config\settings.json`:

```json
"QooCamStudioExe": "D:\\Aplicaciones\\QooCamStudio\\QooCamStudio.exe"
```

Las correcciones de interfaz específicas de otra PC se realizan en `qcam_batch_automator.py`, se recompila el `.exe` y se publican por Git para mantener una sola versión compatible. Los comentarios no pueden añadirse dentro del `.exe` ya compilado: por eso la explicación se conserva aquí y al inicio del fuente.

Antes de recompilar, ejecuta `python -m unittest test_batch_inputs.py`. Para generar el ejecutable, instala las dependencias del fuente y ejecuta `pyinstaller --noconfirm --clean QooCam_VR180_Batch_AntiShake.spec` dentro de esta carpeta.

## Instrucción breve para otro agente

> Lee primero este README y el comentario inicial de `qcam_batch_automator.py`. No supongas que los MP4 dentro de `KDOutput`, `Proxies` o `Right25` son originales. Antes de cambiar la automatización por una pantalla diferente, revisa `automator.log` y las capturas guardadas. Conserva la estrategia de localizar controles y calcular clics desde sus rectángulos: no sustituyas eso por coordenadas fijas.
