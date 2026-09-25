# ============================================================
# How often is a good Nutri-Score ultra-processed?
# Nutri-Score vs NOVA processing groups in packaged foods sold in Switzerland,
# with Germany and France for comparison. Open Food Facts snapshot, September 2026.
#
# Data: Open Food Facts (https://world.openfoodfacts.org), Open Database License (ODbL 1.0).
# The input file is produced by scripts/filter_off.sh from the full Open Food Facts CSV export.
# Run from the repository root.
# ============================================================

library(data.table)
library(ggplot2)

DATA_FILE <- "data/off_ch_de_fr_subset.tsv.gz"
if (!file.exists(DATA_FILE))
  stop("Input missing. Download https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz ",
       "and run: bash scripts/filter_off.sh <path to the downloaded file>")
dir.create("results", showWarnings = FALSE)
dir.create("figures", showWarnings = FALSE)
set.seed(2026)

ci <- function(k, n) if (n > 0) binom.test(k, n)$conf.int[1:2] else c(NA, NA)   # Clopper-Pearson 95% CI

# ---- Load -----------------------------------------------------------------
d <- fread(DATA_FILE, sep = "\t", quote = "", na.strings = c("", "NA"),
           colClasses = list(character = "code"))
n_loaded <- nrow(d)

# One row per barcode: keep the most recently modified record
setorder(d, code, -last_modified_t)
d <- d[!duplicated(code)]

# Countries in which the product is sold (a product can be sold in several)
has_tag <- function(x, tag) grepl(paste0("(^|,)", tag, "(,|$)"), x)
d[, `:=`(CH = has_tag(countries_tags, "en:switzerland"),
         DE = has_tag(countries_tags, "en:germany"),
         FR = has_tag(countries_tags, "en:france"))]

# Nutrient plausibility (used only as a sensitivity filter; both scores are computed by Open Food Facts)
nut <- c("fat_100g", "saturated-fat_100g", "carbohydrates_100g", "sugars_100g", "fiber_100g", "proteins_100g", "salt_100g")
d[, implausible := Reduce(`|`, lapply(nut, function(v) !is.na(get(v)) & (get(v) < 0 | get(v) > 100))) |
      (!is.na(`saturated-fat_100g`) & !is.na(fat_100g) & `saturated-fat_100g` > fat_100g + 0.1) |
      (!is.na(sugars_100g) & !is.na(carbohydrates_100g) & sugars_100g > carbohydrates_100g + 0.1) |
      (!is.na(`energy-kcal_100g`) & (`energy-kcal_100g` < 0 | `energy-kcal_100g` > 900))]

# ---- Analysis sample: products with both a Nutri-Score (A-E) and a NOVA group (1-4) ----
d[, has_nutri := nutriscore_grade %in% c("a", "b", "c", "d", "e")]
d[, has_nova  := nova_group %in% 1:4]
a <- d[has_nutri & has_nova]
a[, grade := factor(toupper(nutriscore_grade), levels = c("A", "B", "C", "D", "E"))]
a[, upf := nova_group == 4]                       # NOVA 4 = ultra-processed (as classified by Open Food Facts)
a[, ab  := grade %in% c("A", "B")]
a[, food_group := fifelse(is.na(pnns_groups_2) | pnns_groups_2 == "unknown", "Uncategorised", pnns_groups_2)]

flow <- rbindlist(lapply(c("CH", "DE", "FR"), function(cc) data.table(
  country = cc,
  products_listed   = sum(d[[cc]]),
  with_nutriscore   = sum(d[[cc]] & d$has_nutri),
  with_nova         = sum(d[[cc]] & d$has_nova),
  with_both         = sum(d[[cc]] & d$has_nutri & d$has_nova))))
flow[, share_with_both := with_both / products_listed]
EXPORT_ROWS <- 4535553   # products in the full export of 24 Sep 2026 (gzip -dc | wc -l, minus header)
flow_meta <- data.table(step = c("products in the full Open Food Facts export", "rows in filtered file (CH/DE/FR)", "unique barcodes"),
                        n = c(EXPORT_ROWS, n_loaded, nrow(d)))
flow
ch <- a[CH == TRUE]

# ============================================================
# Q1 (CH): How does NOVA group vary across Nutri-Score grades?
# ============================================================
q1 <- ch[, .(n = .N, nova1 = sum(nova_group == 1), nova2 = sum(nova_group == 2),
             nova3 = sum(nova_group == 3), nova4 = sum(nova_group == 4)), keyby = grade]
q1[, share_nova4 := nova4 / n]
q1[, c("lo", "hi") := as.data.table(t(mapply(ci, nova4, n)))]
q1

headline <- function(x) {
  k1 <- sum(x$ab & x$upf); n1 <- sum(x$ab)       # P(NOVA 4 | A or B)
  k2 <- sum(x$ab & x$upf); n2 <- sum(x$upf)      # P(A or B | NOVA 4)
  data.table(n = nrow(x),
             p_nova4_given_ab = k1 / n1, p_nova4_given_ab_lo = ci(k1, n1)[1], p_nova4_given_ab_hi = ci(k1, n1)[2],
             n_ab = n1, n_ab_nova4 = k1,
             p_ab_given_nova4 = k2 / n2, p_ab_given_nova4_lo = ci(k2, n2)[1], p_ab_given_nova4_hi = ci(k2, n2)[2],
             n_nova4 = n2,
             share_nova4 = mean(x$upf))
}

# Rank agreement between the two systems: Spearman correlation, bootstrap CI over products
spearman_boot <- function(x, B = 2000) {
  set.seed(2026)
  r  <- cor(x$nutriscore_score, x$nova_group, method = "spearman")
  bs <- replicate(B, { i <- sample.int(nrow(x), replace = TRUE); cor(x$nutriscore_score[i], x$nova_group[i], method = "spearman") })
  c(rho = r, lo = unname(quantile(bs, 0.025)), hi = unname(quantile(bs, 0.975)))
}

# Check: rank correlation using the grade (A-E) instead of points (points are on different scales
# for beverages, fats and cheese), all products and foods only
spearman_grade <- data.table(
  measure = c("points, all products", "grade A-E, all products", "grade A-E, foods only (no beverages)"),
  rho = c(cor(ch$nutriscore_score, ch$nova_group, method = "spearman"),
          cor(as.integer(ch$grade), ch$nova_group, method = "spearman"),
          cor(as.integer(ch[pnns_groups_1 != "Beverages"]$grade), ch[pnns_groups_1 != "Beverages"]$nova_group, method = "spearman")))
spearman_grade

# ============================================================
# Q2 (CH): Among Nutri-Score A/B products, which food groups are most often NOVA 4?
# ============================================================
q2 <- ch[ab == TRUE, .(n_ab = .N, n_ab_nova4 = sum(upf)), by = food_group]
q2[, share := n_ab_nova4 / n_ab]
q2[, c("lo", "hi") := as.data.table(t(mapply(ci, n_ab_nova4, n_ab)))]
q2[, share_of_all_ab_nova4 := n_ab_nova4 / sum(n_ab_nova4)]
setorder(q2, -share)
q2

# ============================================================
# Q3: Is the pattern the same in Germany and France? (replication in larger samples)
# ============================================================
q3_grade <- rbindlist(lapply(c("CH", "DE", "FR"), function(cc) {
  x <- a[get(cc) == TRUE]
  x[, .(country = cc, n = .N, nova4 = sum(upf)), keyby = grade]
}))
q3_grade[, share_nova4 := nova4 / n]
q3_grade[, c("lo", "hi") := as.data.table(t(mapply(ci, nova4, n)))]

# Direct standardisation of P(NOVA 4 | A or B) to one common food-group mix
# (removes differences that only reflect which food groups are listed in each country).
# Reference mix: food groups with >= 10 A/B products in every country; weights = pooled A/B products,
# each country's products counted once per country tag. Uncategorised products are excluded.
ab_long <- rbindlist(lapply(c("CH", "DE", "FR"), function(cc)
  a[get(cc) == TRUE & ab == TRUE & food_group != "Uncategorised", .(country = cc, food_group, upf)]))
cnt <- dcast(ab_long[, .N, by = .(country, food_group)], food_group ~ country, value.var = "N", fill = 0)
common <- cnt[CH >= 10 & DE >= 10 & FR >= 10, food_group]
w <- ab_long[food_group %in% common, .N, by = food_group][, .(food_group, w = N / sum(N))]
std_est <- function(x) { s <- x[, .(p = mean(upf)), by = food_group]; s <- merge(w, s, by = "food_group"); sum(s$w * s$p) }
std <- rbindlist(lapply(c("CH", "DE", "FR"), function(cc) {
  x <- ab_long[country == cc & food_group %in% common]
  est <- std_est(x)
  bs <- replicate(1000, std_est(x[, .SD[sample.int(.N, replace = TRUE)], by = food_group]))   # bootstrap within food groups
  data.table(country = cc, strata = length(common), n = nrow(x), standardised = est,
             lo = quantile(bs, 0.025), hi = quantile(bs, 0.975))
}))
std

# Products listed in one country only (no overlap between the three samples)
exclusive <- rbindlist(lapply(c("CH", "DE", "FR"), function(cc) {
  others <- setdiff(c("CH", "DE", "FR"), cc)
  x <- a[get(cc) == TRUE & get(others[1]) == FALSE & get(others[2]) == FALSE & ab == TRUE]
  r <- ci(sum(x$upf), nrow(x))
  data.table(country = cc, n_ab_exclusive = nrow(x), p_nova4_given_ab_exclusive = mean(x$upf), lo = r[1], hi = r[2])
}))
overlap_ch <- a[CH == TRUE & ab == TRUE, mean(DE | FR)]   # share of Swiss A/B products also tagged DE or FR
exclusive; overlap_ch

q3 <- rbindlist(lapply(c("CH", "DE", "FR"), function(cc) {
  x <- a[get(cc) == TRUE]
  sp <- spearman_boot(x, B = if (cc == "CH") 2000 else 500)
  cbind(data.table(country = cc), headline(x), spearman = sp["rho"], spearman_lo = sp["lo"], spearman_hi = sp["hi"])
}))
q3 <- merge(q3, std[, .(country, p_nova4_given_ab_standardised = standardised, std_lo = lo, std_hi = hi, std_strata = strata)], by = "country")
q3 <- merge(q3, exclusive, by = "country")
q3

# External check: Sarda et al. (2024), same database, products sold in France, updated Nutri-Score:
# 12.5% of NOVA 4 products were rated A or B.
external_check <- data.table(source = c("Sarda et al. 2024 (France, Open Food Facts, updated algorithm)", "This analysis (France)"),
                             p_ab_given_nova4 = c(0.125, q3[country == "FR", p_ab_given_nova4]))
external_check

# ============================================================
# Q4 (CH): Is the result driven by rarely scanned (possibly obscure) products?
# unique_scans_n = number of distinct IP addresses that scanned the product with the official Open Food Facts
# apps in one calendar year (computed by Open Food Facts from server logs, scripts/scanbot.pl).
# A rough proxy for how often a product is looked up, not for sales.
# ============================================================
ch_ab <- ch[ab == TRUE]
ch_ab[, scan_bin := cut(unique_scans_n, breaks = c(0, 1, 4, 19, 99, Inf),
                        labels = c("1", "2–4", "5–19", "20–99", "100+"), right = TRUE)]
ch_ab[, scan_bin := factor(fifelse(is.na(scan_bin), "no scans", as.character(scan_bin)),
                           levels = c("no scans", "1", "2–4", "5–19", "20–99", "100+"))]
q4 <- ch_ab[, .(n_ab = .N, n_ab_nova4 = sum(upf)), keyby = scan_bin]
q4[, share := n_ab_nova4 / n_ab]
q4[, c("lo", "hi") := as.data.table(t(mapply(ci, n_ab_nova4, n_ab)))]
q4

# Trend: odds of NOVA 4 per doubling of scans, crude and within food group
sc <- ch_ab[!is.na(unique_scans_n) & unique_scans_n >= 1]
m_crude <- glm(upf ~ log2(unique_scans_n), family = binomial, data = sc)
m_adj   <- glm(upf ~ log2(unique_scans_n) + food_group, family = binomial, data = sc)
or_row  <- function(m) exp(c(coef(m)[2], confint.default(m)[2, ]))
q4_trend <- data.table(model = c("crude", "adjusted for food group"),
                       rbind(or_row(m_crude), or_row(m_adj)))
setnames(q4_trend, 2:4, c("or_per_doubling_of_scans", "lo", "hi"))
q4_trend[, n := nrow(sc)]
q4_trend

# Audit: artificially sweetened beverages rated A/B. The updated algorithm penalises non-nutritive sweeteners in
# beverages, so diet drinks rated A/B suggest the sweeteners were not recognised in the ingredient list.
audit_sweetened <- ch[ab == TRUE & pnns_groups_2 == "Artificially sweetened beverages",
                      .(code, product_name, brands, grade, nutriscore_score, nova_group, main_category_en)]
audit_sweetened

# ============================================================
# Sensitivity of the CH headline, P(NOVA 4 | A or B)
# ============================================================
sens_one <- function(label, x, weights = NULL) {
  y <- x[ab == TRUE]
  if (is.null(weights)) {
    k <- sum(y$upf); n <- nrow(y); r <- ci(k, n)
    data.table(analysis = label, n_ab = n, estimate = k / n, lo = r[1], hi = r[2])
  } else {
    y <- y[!is.na(get(weights)) & get(weights) > 0]
    wm <- function(i) weighted.mean(y$upf[i], y[[weights]][i])
    bs <- replicate(2000, wm(sample.int(nrow(y), replace = TRUE)))
    data.table(analysis = label, n_ab = nrow(y), estimate = wm(seq_len(nrow(y))),
               lo = quantile(bs, 0.025), hi = quantile(bs, 0.975))
  }
}
sensitivity <- rbindlist(list(
  sens_one("Main analysis (all CH products with both scores)", ch),
  sens_one("Excluding uncategorised products", ch[food_group != "Uncategorised"]),
  sens_one("Excluding implausible nutrient values", ch[implausible == FALSE]),
  sens_one("Product page completeness >= 0.8", ch[!is.na(completeness) & completeness >= 0.8]),
  sens_one("Sold in CH only (not tagged DE or FR)", ch[DE == FALSE & FR == FALSE]),
  sens_one("Foods only (excluding beverages)", ch[pnns_groups_1 != "Beverages"]),
  sens_one("Excluding artificially sweetened beverages", ch[is.na(pnns_groups_2) | pnns_groups_2 != "Artificially sweetened beverages"]),
  sens_one("Weighted by number of scans", ch, weights = "unique_scans_n")))
sensitivity

# ============================================================
# Figures (A1 poster; the poster prints titles and captions itself)
# ============================================================
BLUE <- "#2a78d6"; ORANGE <- "#eb6834"; GREY <- "#c9c7c1"; GREY_D <- "#6f6d68"
TEXT <- "#1f1f1e"; TEXT2 <- "#52514e"
FONT_DIR <- "fonts"; PF <- ""
if (requireNamespace("ragg", quietly = TRUE) && requireNamespace("systemfonts", quietly = TRUE) &&
    file.exists(file.path(FONT_DIR, "texgyreheros-regular.otf"))) {
  systemfonts::register_font("PosterSans", plain = file.path(FONT_DIR, "texgyreheros-regular.otf"),
                             bold = file.path(FONT_DIR, "texgyreheros-bold.otf"))
  PF <- "PosterSans"
}
save_poster <- function(file, plot, height = 6.2) {
  if (PF != "") ggsave(file, plot, width = 10, height = height, dpi = 300, device = ragg::agg_png)
  else          ggsave(file, plot, width = 10, height = height, dpi = 300)
}
pct  <- function(x) paste0(round(100 * x), "%")
num  <- function(x) format(x, big.mark = ",", trim = TRUE)
theme_p <- theme_minimal(base_size = 19, base_family = PF) +
  theme(plot.subtitle = element_text(size = 15.5, colour = TEXT2, margin = margin(b = 12)),
        plot.title.position = "plot", plot.background = element_rect(fill = "white", colour = NA),
        plot.margin = margin(8, 14, 6, 6), panel.grid.minor = element_blank(),
        panel.grid.major.x = element_blank(),
        panel.grid.major.y = element_line(colour = "#e8e7e3", linewidth = 0.45),
        axis.text = element_text(colour = TEXT2, size = 15),
        axis.title.x = element_text(colour = TEXT2, size = 15, margin = margin(t = 8)),
        legend.position = "top", legend.justification = "left", legend.margin = margin(0, 0, 0, 0),
        legend.text = element_text(colour = TEXT, size = 15), legend.title = element_blank())
update_geom_defaults("text", list(family = PF))

# ---- Poster A: NOVA composition of each Nutri-Score grade (CH) ----
pa <- melt(q1[, .(grade, n, `NOVA 1` = nova1 / n, `NOVA 2–3` = (nova2 + nova3) / n, `NOVA 4` = nova4 / n)],
           id.vars = c("grade", "n"), variable.name = "nova", value.name = "share")
pa[, nova := factor(nova, levels = c("NOVA 4", "NOVA 2–3", "NOVA 1"))]
# stacking order bottom to top: NOVA 1, NOVA 2-3, NOVA 4 (labels placed at segment centres)
pa[, bottom := fcase(nova == "NOVA 1", 0,
                     nova == "NOVA 2–3", share[nova == "NOVA 1"],
                     nova == "NOVA 4", 1 - share[nova == "NOVA 4"]), by = grade]
pa[, ymid := bottom + share / 2]
pa[, lab_col := fifelse(nova == "NOVA 2–3", TEXT, "white")]
pA <- ggplot(pa, aes(x = grade, y = share, fill = nova)) +
  geom_col(width = 0.66, colour = "white", linewidth = 0.8) +
  geom_text(data = pa[share >= 0.06], aes(y = ymid, label = pct(share)), colour = pa[share >= 0.06]$lab_col,
            size = 5.2, fontface = "bold") +
  geom_text(data = q1, aes(x = grade, y = -0.045, label = paste0("n = ", num(n))), inherit.aes = FALSE,
            size = 4.2, colour = TEXT2) +
  scale_fill_manual(values = c("NOVA 1" = BLUE, "NOVA 2–3" = GREY, "NOVA 4" = ORANGE),
                    breaks = c("NOVA 1", "NOVA 2–3", "NOVA 4"),
                    labels = c("NOVA 1: unprocessed / minimally processed", "NOVA 2–3: culinary ingredients / processed",
                               "NOVA 4: ultra-processed")) +
  scale_y_continuous(labels = function(x) paste0(round(100 * x), "%"), breaks = seq(0, 1, 0.25),
                     expand = expansion(mult = c(0.02, 0.01))) +
  guides(fill = guide_legend(ncol = 1, reverse = FALSE)) +
  labs(subtitle = NULL, x = "Nutri-Score grade (as computed by Open Food Facts)", y = NULL) +
  theme_p + theme(legend.text = element_text(size = 14))

# ---- Poster B: share NOVA 4 among A/B products, by food group (CH) ----
pb <- q2[food_group != "Uncategorised" & n_ab >= 50]
pb[, food_group := factor(food_group, levels = rev(pb$food_group))]
pB <- ggplot(pb, aes(y = food_group, x = share)) +
  geom_segment(aes(x = lo, xend = hi, yend = food_group), colour = TEXT2, linewidth = 0.55) +
  geom_vline(xintercept = q3[country == "CH", p_nova4_given_ab], linetype = "dashed", colour = TEXT2, linewidth = 0.5) +
  annotate("text", x = q3[country == "CH", p_nova4_given_ab] + 0.01, y = nrow(pb) + 0.95, hjust = 0, size = 3.9, colour = TEXT2,
           label = paste0("all A/B products: ", pct(q3[country == "CH", p_nova4_given_ab]))) +
  geom_point(colour = ORANGE, size = 3.6) +
  geom_label(aes(x = pmax(hi, share) + 0.015, label = paste0(pct(share), "  (", n_ab_nova4, " of ", num(n_ab), ")")),
             hjust = 0, size = 4.0, colour = TEXT2, fill = "white", label.size = 0, label.padding = unit(0.08, "lines"),
             family = PF) +
  scale_x_continuous(labels = function(x) paste0(round(100 * x), "%"), limits = c(0, 1.18),
                     breaks = seq(0, 1, 0.25), expand = c(0, 0)) +
  scale_y_discrete(expand = expansion(add = c(0.6, 1.3))) +
  labs(x = "Share NOVA 4 among Nutri-Score A/B products (95% CI)", y = NULL) +
  theme_p + theme(panel.grid.major.x = element_line(colour = "#e8e7e3", linewidth = 0.45),
                  panel.grid.major.y = element_blank(), axis.text.y = element_text(size = 14, colour = TEXT))

# ---- Poster C: share NOVA 4 by grade, three countries ----
q3_grade[, country_lab := factor(country, levels = c("CH", "DE", "FR"),
                                 labels = c("Switzerland", "Germany", "France"))]
ends <- q3_grade[grade == "E"]
pC <- ggplot(q3_grade, aes(x = grade, y = share_nova4, group = country_lab, colour = country_lab, shape = country_lab)) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0.08, linewidth = 0.6, position = position_dodge(0.35)) +
  geom_line(linewidth = 1.1, position = position_dodge(0.35)) +
  geom_point(size = 3.6, fill = "white", stroke = 1.6, position = position_dodge(0.35)) +
  scale_colour_manual(values = c("Switzerland" = ORANGE, "Germany" = GREY_D, "France" = "#a8a6a0")) +
  scale_shape_manual(values = c("Switzerland" = 21, "Germany" = 22, "France" = 24)) +
  scale_y_continuous(labels = function(x) paste0(round(100 * x), "%"), limits = c(0, 1), breaks = seq(0, 1, 0.25)) +
  labs(x = "Nutri-Score grade", y = NULL) +
  theme_p

# ---- Poster D: P(NOVA 4 | A or B) by scan count (CH) ----
pD <- ggplot(q4, aes(x = scan_bin, y = share)) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0.1, linewidth = 0.6, colour = TEXT2) +
  geom_point(size = 4.6, colour = ORANGE) +
  geom_hline(yintercept = q3[country == "CH", p_nova4_given_ab], linetype = "dashed", colour = TEXT2, linewidth = 0.5) +
  annotate("text", x = 6.45, y = q3[country == "CH", p_nova4_given_ab] - 0.022, hjust = 1, size = 4.2, colour = TEXT2,
           label = paste0("all A/B products: ", pct(q3[country == "CH", p_nova4_given_ab]))) +
  geom_text(aes(y = share + 0.022, label = pct(share)), nudge_x = 0.28, size = 5.2, fontface = "bold", colour = TEXT) +
  geom_text(aes(y = 0.02, label = paste0("n = ", num(n_ab))), size = 4.2, colour = TEXT2) +
  scale_y_continuous(labels = function(x) paste0(round(100 * x), "%"), limits = c(0, 0.6), breaks = seq(0, 0.6, 0.1)) +
  labs(x = "Distinct IP addresses that scanned the product in the app (one year)", y = NULL) +
  theme_p

save_poster("figures/poster_A_nova_by_grade.png",   pA)
save_poster("figures/poster_B_food_groups.png",     pB)
save_poster("figures/poster_C_countries.png",       pC)
save_poster("figures/poster_D_scans.png",           pD)
update_geom_defaults("text", list(family = ""))

# ============================================================
# Check tables (aggregates only) -> results/
# ============================================================
fwrite(rbind(flow_meta, flow[, .(step = paste(country, names(.SD)), n = unlist(.SD)), by = country, .SDcols = c("products_listed","with_nutriscore","with_nova","with_both")][, .(step, n)]),
       "results/data_flow.csv")
fwrite(flow, "results/coverage_by_country.csv")
fwrite(q1, "results/q1_ch_nova_by_grade.csv")
fwrite(q2, "results/q2_ch_ab_nova4_by_food_group.csv")
fwrite(q3, "results/q3_countries_summary.csv")
fwrite(q3_grade[, !"country_lab"], "results/q3_countries_nova4_by_grade.csv")
fwrite(external_check, "results/q3_external_check_sarda2024.csv")
fwrite(q4, "results/q4_ch_ab_nova4_by_scans.csv")
fwrite(q4_trend, "results/q4_ch_scan_trend.csv")
fwrite(sensitivity, "results/sensitivity_ch_headline.csv")
fwrite(audit_sweetened, "results/audit_sweetened_beverages_ab.csv")
fwrite(data.table(file = DATA_FILE, bytes = file.size(DATA_FILE),
                  sha256 = sub(" .*", "", system(paste("sha256sum", shQuote(DATA_FILE)), intern = TRUE)),
                  export_downloaded = "2026-09-24", export_url = "https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz"),
       "results/input_manifest.csv")
writeLines(capture.output(sessionInfo()), "results/session_info.txt")
fwrite(spearman_grade, "results/q1_ch_spearman_checks.csv")
fwrite(std, "results/q3_countries_standardised.csv")
fwrite(data.table(measure = "share of Swiss A/B products also tagged DE or FR", value = overlap_ch), "results/q3_overlap_ch.csv")
