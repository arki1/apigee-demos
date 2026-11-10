/*eslint strict: ["error", "never"]*/

function parseRows(queryResponse) {
    var rows = [];
    if (queryResponse.totalRows > 0) {
        for (var i=0; i < queryResponse.rows.length; i++) {
            var row = {};
            for (var j=0; j< queryResponse.rows[i].f.length; j++) {
                row[queryResponse.schema.fields[j].name] = queryResponse.rows[i].f[j].v;
            }
            rows.push(row);
        }
    }
    return rows;
}

// This makes the library visible outside of this function block
library = {
    parseRows: parseRows
};