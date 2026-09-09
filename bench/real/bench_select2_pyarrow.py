import sys, time
import pyarrow as pa
import pyarrow.dataset as ds
import pyarrow.compute as pc
import pyarrow.csv as pacsv

path = sys.argv[1]
t0 = time.time()
convert_options = pacsv.ConvertOptions(column_types={"rate_code_id": pa.string()})
file_format = ds.CsvFileFormat(convert_options=convert_options)
dataset = ds.dataset(path, format=file_format)
table = dataset.to_table(filter=pc.field("rate_code_id") == "6", columns=["trip_id", "fare_amount"])
dt = time.time() - t0
print(f"rows={table.num_rows} time={dt:.4f}s")
