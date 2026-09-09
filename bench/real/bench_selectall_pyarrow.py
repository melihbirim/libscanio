import sys, time, csv
import pyarrow as pa
import pyarrow.dataset as ds
import pyarrow.compute as pc
import pyarrow.csv as pacsv

path = sys.argv[1]
with open(path, newline="", encoding="utf-8") as f:
    header = next(csv.reader(f))
t0 = time.time()
convert_options = pacsv.ConvertOptions(column_types={name: pa.string() for name in header})
file_format = ds.CsvFileFormat(convert_options=convert_options)
dataset = ds.dataset(path, format=file_format)
table = dataset.to_table(filter=pc.field("rate_code_id") == "6")
dt = time.time() - t0
print(f"rows={table.num_rows} time={dt:.4f}s")
