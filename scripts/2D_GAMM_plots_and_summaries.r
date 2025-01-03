library(mgcv)
library(tidyverse)
library(lme4)
library(mgcViz)
library(glue)
library(fs)
library(stringr)
library(readr)

model_dir <- Sys.getenv('MODEL_DIR')
word_filepath <- "./assets/wordlist.txt"
plots_and_summaries_dir <- "./plots/2D_GAMM_plots_and_summaries"
if (!dir.exists(plots_and_summaries_dir)){
    dir.create(plots_and_summaries_dir)}
 
prediction_datasets_dir <- "./datasets/2D_GAMM_predictions"
if (!dir.exists(prediction_datasets_dir)){
    dir.create(prediction_datasets_dir)}

words <- str_trim(readLines(word_filepath))


for (word in words){
    print(glue("Starting on {word}..."))
    word_tibble <- read.csv(glue("./clusters/{word}_cluster_counts.csv"))
    word_long <- word_tibble %>%
    select(-matches("^cluster_\\d+$")) %>% # Super roundabout, but we exclude the `cluster_<number>` columns here to recalculate them after pivoting
    pivot_longer(
        cols = starts_with("cluster_"),  # Select columns that start with "cluster_"
        names_to = "cluster_number",     # Name of the new column for the cluster numbers # nolint: line_length_linter.
        names_prefix = "cluster_",       # Remove the prefix "cluster_" from the original column names
        values_to = "cluster_p"          # Name of the new column for the cluster probabilities # nolint: line_length_linter.
    ) %>%
    mutate(cluster_number = factor(as.numeric(str_extract(cluster_number, "\\d+")))) %>%
    mutate(n_cluster = round(cluster_p*n))
    print("Word data processed!")
    ### Pulling the cluster numbers that have been modelled:
    model_files <- dir_ls(model_dir)
    word_files <- model_files[grepl(glue("{word}-"), model_files) & grepl(glue("-2D_GAMM.rds"), model_files)]
    for (file in word_files){
        cluster <- str_extract(file, "(?<=-)[^-]+(?=-)")
        plot_filename <- glue("{plots_and_summaries_dir}/{word}-{cluster}-2D_GAMM_plot.png")
        summary_filename <- glue("{plots_and_summaries_dir}/{word}-{cluster}-summary.txt")
        if (!(file.exists(plot_filename) & file.exists(summary_filename))){
            try({
                word_sense_indexed <- word_long %>% filter(cluster_number==cluster)
                #
                model <- readRDS(file)
                print("GAMM loaded successfully!")
                model_summary <- capture.output(summary(model, re.test=FALSE))
                model_summary_str <- paste(model_summary, collapse = "\n")
                #
                yob_range <- seq(min(word_sense_indexed$yob), max(word_sense_indexed$yob), by=1)
                year_range <- seq(min(word_sense_indexed$year), max(word_sense_indexed$year), by=1)
                age_min <- round(mean(word_sense_indexed$age) - 3*sd(word_sense_indexed$age))
                age_max <- round(mean(word_sense_indexed$age) + 3*sd(word_sense_indexed$age))
                #
                pred_data <- expand.grid(yob = yob_range, year = year_range) %>%
                mutate(age = year - yob) %>% 
                mutate(speakerid = first(word_sense_indexed$speakerid), speakerXsessionid = first(word_sense_indexed$speakerXsessionid)) %>%# Just so the mgcv:predict fn doesn't throw up an error asking for speakerid values -- this won't matter because we exclude the by-speaker effects ## Confirmed later, changing this doesn't affect preds
                filter(age >= age_min & age <= age_max)
                preds <- mgcv::predict.bam(model, newdata=pred_data, type="response", exclude='s(speakerXsessionid)')
                pred_data$probability = preds
                pred_data_filename <- glue("{prediction_datasets_dir}/{word}-{cluster}.csv")
                write_csv(pred_data, pred_data_filename)
                print("Prediction data generated and saved!")
                #
                plot <- ggplot(pred_data, aes(x = age, y = year, fill = probability)) + 
                    geom_tile() +  # Creates the heatmap
                    scale_fill_gradient(low = "turquoise", high = "yellow", name = "Predicted\nProbability", limits=c(0,1)) +
                    geom_contour(aes(z = probability), color= 'black') + 
                    labs(x = "Age", y = "Year", title = glue("Model-Predicted Probability of\nSense {cluster} of {word}")) +
                    theme_minimal() + 
                    theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 18),  # Adjust size for x-axis numeric tick labels
                            axis.text.y = element_text(size = 18),
                            axis.title.x = element_text(size = 18), # Change font size and style for x-axis label
                            axis.title.y = element_text(size = 18))
                #
                print("Plot created!")
                print("Saving plot...")
                ggsave(plot_filename, plot, width=8, height=6, dpi=300)
                writeLines(model_summary_str, summary_filename)
                print(glue("Done with sense {cluster}"))
                rm(model, word_sense_indexed)
                gc()
            })
        }
    } 
    rm(word_long, word_tibble)
    gc()
}




