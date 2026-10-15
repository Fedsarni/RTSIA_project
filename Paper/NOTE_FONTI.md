# Copertura delle fonti

Documento: `paper.tex`. Classe: `IEEEtran`, opzione `conference`, due colonne. Lingua: italiano.

## Tabelle e immagini incluse

Tabella tab:models: 0 Infrastruttura 3f415766814f80a7bddcdbc430a4e676.md, tabella 1, 4 righe dati.
Tabella tab:platform: 0 Infrastruttura 3f415766814f80a7bddcdbc430a4e676.md, tabella 2, 8 righe dati.
Figura fig:ros: 0 Infrastruttura/rtsia.drawio.png -> plots/markdown/0_infrastruttura/rtsia.drawio.png
Tabella tab:blocks: 0 Infrastruttura 3f415766814f80a7bddcdbc430a4e676.md, tabella 3, 5 righe dati.
Tabella tab:b1: B1 Baseline 3f415766814f807eb936fdbd12d0b4de.md, tabella 1, 2 righe dati.
Figura fig:b1e2e: B1 Baseline/boxplot_latenza_e2e_singoli.png -> plots/markdown/b1_baseline/boxplot_latenza_e2e_singoli.png
Figura fig:b1tail: B1 Baseline/tail_latencies.png -> plots/markdown/b1_baseline/tail_latencies.png
Figura fig:b1phases: B1 Baseline/Prefill_decode.png -> plots/markdown/b1_baseline/Prefill_decode.png
Figura fig:b1accuracy: B1 Baseline/accuracy.png -> plots/markdown/b1_baseline/accuracy.png
Tabella tab:b2: B2 Co-location 3f515766814f80b0a54be50dac8501d6.md, tabella 1, 1 righe dati.
Figura fig:b2e2e: B2 Co-location/bp_latenzaE2E.png -> plots/markdown/b2_co_location/bp_latenzaE2E.png
Figura fig:b2comparison: B2 Co-location/boxplot_latenza_e2e_singoli.png -> plots/markdown/b2_co_location/boxplot_latenza_e2e_singoli.png
Figura fig:b2inf: B2 Co-location/boxplot_infer_ms.png -> plots/markdown/b2_co_location/boxplot_infer_ms.png
Figura fig:b2jitter: B2 Co-location/jitter_infer_ms.png -> plots/markdown/b2_co_location/jitter_infer_ms.png
Figura fig:b2phases: B2 Co-location/Prefill_decode.png -> plots/markdown/b2_co_location/Prefill_decode.png
Figura fig:b2decode: B2 Co-location/decodePrefill.png -> plots/markdown/b2_co_location/decodePrefill.png
Tabella tab:b3: B3 Interference 3f515766814f809f9f93c35e6fb5da1e.md, tabella 1, 16 configurazioni distinte (17 righe nella fonte).
Figura fig:b3inf: B3 Interference/boxplot_infer_ms.png -> plots/markdown/b3_interference/boxplot_infer_ms.png
Figura fig:b3e2e: B3 Interference/boxplots_e2e.png -> plots/markdown/b3_interference/boxplots_e2e.png
Figura fig:b3tail: B3 Interference/tail_latencies.png -> plots/markdown/b3_interference/tail_latencies.png
Figura fig:b3jitter: B3 Interference/jitter_infer_ms.png -> plots/markdown/b3_interference/jitter_infer_ms.png
Figura fig:b3phases: B3 Interference/prefill_decode.png -> plots/markdown/b3_interference/prefill_decode.png
Figura fig:b3semif: B3 Interference/chart_memstream_model_semif.png -> plots/markdown/b3_interference/chart_memstream_model_semif.png
Figura fig:b3gemma: B3 Interference/chart_memstream_model_gemma.png -> plots/markdown/b3_interference/chart_memstream_model_gemma.png
Tabella tab:resources: B3 Interference 3f515766814f809f9f93c35e6fb5da1e.md, tabella 2, 6 righe dati.
Tabella tab:b4: B4 Isolation 3f915766814f80489d6dd6fa35e45974.md, tabella 1, 18 righe dati.
Figura fig:b4e2e: B4 Isolation/Box_plots_e2e.png -> plots/markdown/b4_isolation/Box_plots_e2e.png
Figura fig:b4inf: B4 Isolation/boxplot_infer_ms.png -> plots/markdown/b4_isolation/boxplot_infer_ms.png
Figura fig:b4tail: B4 Isolation/tail_latencies.png -> plots/markdown/b4_isolation/tail_latencies.png
Figura fig:b4jitter: B4 Isolation/jitter_infer_ms.png -> plots/markdown/b4_isolation/jitter_infer_ms.png
Tabella tab:b5: B5 isolation+co_location 3f915766814f8027a381c273c4b54c1d.md, tabella 1, 10 righe dati.
Figura fig:b5inf: B5 isolation+co_location/boxplot_infer_ms.png -> plots/markdown/b5_isolation_co_location/boxplot_infer_ms.png
Figura fig:b5e2e: B5 isolation+co_location/Boxplots_e2e.png -> plots/markdown/b5_isolation_co_location/Boxplots_e2e.png
Figura fig:b5tail: B5 isolation+co_location/Tail_latencies.png -> plots/markdown/b5_isolation_co_location/Tail_latencies.png
Figura fig:b5jitter: B5 isolation+co_location/jitter_infer_ms.png -> plots/markdown/b5_isolation_co_location/jitter_infer_ms.png

## Riferimenti a immagini non disponibili

Nessuno nei sette Markdown presenti al termine della redazione.


## Note editoriali

- Conservato il documento precedente in `paper_precedente.tex`.
- Sezioni principali ricavate dai titoli 0, B1–B5 e Conclusioni.
- Tutte le tabelle Markdown incluse; la configurazione Gemma/sched_switch duplicata nel piano B3 è rappresentata una sola volta.
- Esempi JSON ripuliti dalle concatenazioni di stringhe e dalle virgole mancanti presenti nel Markdown, senza cambiare le strutture descritte.
- Nessun dato sperimentale aggiunto per immagini mancanti, cyclictest o log CSV non disponibili.
- Distinte le ipotesi causali dai risultati osservati; non affermate garanzie hard real-time.
- Omesse la stima teorica non ricostruibile di 11 token/s e le prestazioni dichiarate di modelli esterni non testati.

## Compilazione

```sh
cd Paper
latexmk -pdf -interaction=nonstopmode -halt-on-error paper.tex
```

## Verifica finale

Compilazione completata con latexmk: PDF di 12 pagine. Verificati 26 riferimenti grafici, 9 tabelle, 4 esempi JSON e tutti i riferimenti interni. Nessun errore, riferimento irrisolto o avviso di contenuto fuori margine.

## Revisione del testo

Sommario riorganizzato attorno a problema, limiti, approccio proposto e metodologia sperimentale. Eliminati dal paper tutti i riferimenti alla disponibilità delle fonti, ai materiali forniti e alla costruzione del documento; rimosse le appendici editoriali.

## Revisione delle fonti scientifiche e dell’impaginazione

- Sommario aggiornato e distinzione System One/System Two attribuita alla proposta TypeSafe.
- SemIf/OpenJev descritto come implementazione aperta indipendente dell’interfaccia decisionale, senza attribuirgli il modello o l’addestramento proprietari di Jev.
- Descritta la modalità direct: passaggio unico di Qwen3.5 4B congelato, softmax sui logit dei token delle alternative e assenza di campionamento dei token di risposta.
- Aggiunti cinque riferimenti bibliografici: TypeSafe, repository SemIf, metodo SemIf, panoramica Gemma e scheda Gemma 4.
- Figure distribuite nelle sottosezioni pertinenti; impedita la comparsa prima del richiamo testuale e limitato lo spostamento oltre la discussione associata.
- Piani sperimentali impaginati su singola colonna per evitare pagine quasi vuote causate dalle tabelle a doppia colonna.
- Conservate tutte le 26 immagini e le 9 tabelle; verificata anche l’impaginazione mediante anteprime del PDF.
