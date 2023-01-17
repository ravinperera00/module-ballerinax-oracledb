// Copyright (c) 2022 WSO2 LLC. (https://www.wso2.com) All Rights Reserved.
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/sql;

# Represents an SQL metadata client.
isolated client class SchemaClient {
    private final Client dbClient;
    private final string database;

    # Initializes the Schema Client 
    #
    # + host - Hostname of the Oracle database server
    # + user - Name of a user of the Oracle database server
    # + password - The password of the Oracle database server for the provided username
    # + database - System identifier or the service name of the database
    # + port - Port number of the Oracle database server
    # + options - Oracle database connection properties
    # + connectionPool - The `sql:ConnectionPool` object to be used within the client. If there is no
    #                    `connectionPool` provided, the global connection pool will be used
    # + return - An `sql:Error` if the client creation fails
    public function init(string host, string user, string password, string database, int port, 
            Options? options = (), sql:ConnectionPool? connectionPool = ()) returns sql:Error? {
        self.database = database;
        self.dbClient = check new (host, user, password, database, port, options, connectionPool);
    }

    # Retrieves all tables in the database.
    #
    # + return - A string array containing the names of the tables or an `sql:Error`
    isolated remote function listTables() returns string[]|sql:Error {
        string[] tables = [];
        stream<record {}, sql:Error?> tableStream = self.dbClient->query(
            `SELECT TABLE_NAME FROM all_tables
             WHERE owner = ${self.database};`
        );

        do {
            tables = check from record {} 'table in tableStream
                select <string>'table["TABLE_NAME"];
        } on fail error e {
            return error sql:Error(string `Error while listing the tables in the ${self.database} database.`, cause = e);
        }

        check tableStream.close();

        return tables;
    }

    # Retrieves information relevant to the provided table in the database.
    #
    # + tableName - The name of the table
    # + include - Options on whether column and constraint related information should be fetched.
    #             If `NO_COLUMNS` is provided, then no information related to columns will be retrieved.
    #             If `COLUMNS_ONLY` is provided, then columnar information will be retrieved, but not constraint
    #             related information.
    #             If `COLUMNS_WITH_CONSTRAINTS` is provided, then columar information along with constraint related
    #             information will be retrieved
    # + return - An 'sql:TableDefinition' with the relevant table information or an `sql:Error`
    isolated remote function getTableInfo(string tableName, sql:ColumnRetrievalOptions include = sql:COLUMNS_ONLY) returns sql:TableDefinition|sql:Error {
        record {}|sql:Error 'table = self.dbClient->queryRow(
            `SELECT object_type FROM all_objects
             WHERE owner = ${self.database} AND object_name = ${tableName};`
        );

        if 'table is sql:NoRowsError {
            return error sql:NoRowsError("The selected table does not exist or the user does not have the required privilege level to view the table.");
        } else if 'table is sql:Error {
            return 'table;
        } else {
            if ('table["object_type"] == "TABLE"){
                'table["object_type"] = "BASE TABLE";
            }

            sql:TableDefinition tableDef = {
                name: tableName,
                'type: <sql:TableType>'table["object_type"]
            };

            if !(include == sql:NO_COLUMNS) {
                sql:ColumnDefinition[] columns = check self.getColumns(tableName);

                tableDef.columns = columns;

                if include == sql:COLUMNS_WITH_CONSTRAINTS {
                    tableDef = check self.getConstraints(tableName, tableDef);
                }    
            }

            return tableDef;
        }
    }

    # Retrieves all routines in the database.
    #
    # + return - A string array containing the names of the routines or an `sql:Error`
    isolated remote function listRoutines() returns string[]|sql:Error {
        string[] routines = [];
        stream<record {}, sql:Error?> routineStream = self.dbClient->query(
            `SELECT object_name FROM all_objects
            WHERE owner = ${self.database} AND object_type = 'PROCEDURE' OR object_type = 'FUNCTION';`
        );

        do {
            routines = check from record {} 'routine in routineStream
                select <string>'routine["object_name"];
        } on fail error e {
            return error(string `Error while listing routines in the ${self.database} database.`, cause = e);
        }

        check routineStream.close();

        return routines;
    }

    # Retrieves information relevant to the provided routine in the database.
    #
    # + name - The name of the routine
    # + return - An 'sql:RoutineDefinition' with the relevant routine information or an `sql:Error`
    isolated remote function getRoutineInfo(string name) returns sql:RoutineDefinition|sql:Error {
        record {}|sql:Error routineRecord = self.dbClient->queryRow(
            `SELECT object_name, object_type, return_type FROM all_procedures
             WHERE object_name = ${name};`
        );

        if routineRecord is sql:NoRowsError {
            return error sql:NoRowsError(string `Selected routine does not exist in the ${self.database} database, or the user does not have required privilege level to view it.`);
        } else if routineRecord is sql:Error {
            return routineRecord;
        } else {
            sql:ParameterDefinition[] params = check self.getParameters(name);

            sql:RoutineDefinition routine = {
                name: <string>routineRecord["object_name"],
                'type: <sql:RoutineType>routineRecord["object_type"],
                returnType: <string?>routineRecord["return_type"],
                parameters: params
            };            

            return routine;
        }
    }

    # Retrieves column information of the provided table in the database.
    #
    # + tableName - The name of the table
    # + return - An 'sql:ColumnDefinition[]' or an `sql:Error`
    isolated function getColumns(string tableName) returns sql:ColumnDefinition[]|sql:Error {
        sql:ColumnDefinition[] columns = [];
        stream<record {}, sql:Error?> colResults = self.dbClient->query(
            `SELECT column_name, data_type, data_default, nullable FROM all_tab_columns
             WHERE owner = ${self.database} AND table_name = ${tableName};`
        );
        do {
            check from record {} result in colResults
                do {
                    sql:ColumnDefinition column = {
                        name: <string>result["column_name"],
                        'type: <string>result["data_type"],
                        defaultValue: result["data_default"],
                        nullable: (<string>result["nullable"]) == "Y" ? true : false
                    };
                    columns.push(column);
                };
        } on fail error e {
            return error sql:Error(string `Error while reading column info in the ${tableName} table, in the ${self.database} database.`, cause = e);
        }

        check colResults.close();

        return columns;
    }

    # Retrieves constraints information of the provided table in the database.
    #
    # + tableName - The name of the table
    # + tableDef - The table definition created in getTableInfo()
    # + return - An 'sql:TableDefinition' now including the constraint information or an `sql:Error`
    isolated function getConstraints(string tableName, sql:TableDefinition tableDef) returns sql:TableDefinition|sql:Error {
        sql:CheckConstraint[] checkConstList =  [];

        stream<record {}, sql:Error?> checkResults = self.dbClient->query(
            `SELECT DISTINCT UC.CONSTRAINT_NAME, UC.SEARCH_CONDITION
            FROM USER_CONSTRAINTS UC
            JOIN USER_TABLES UT
            ON UC.TABLE_NAME = UT.TABLE_NAME
            WHERE UC.CONSTRAINT_TYPE = ${self.database} AND UT.TABLE_NAME = ${tableName};`
        );
        do {
            check from record {} result in checkResults
                do {
                    sql:CheckConstraint 'check = {
                        name: <string>result["CONSTRAINT_NAME"],
                        clause: <string>result["SEARCH_CONDITION"]
                    };
                    checkConstList.push('check);
                };
        } on fail error e {
            return error sql:Error(string `Error while reading check constraints in the ${self.database} database.`, cause = e);
        }

        check checkResults.close();        

        tableDef.checkConstraints = checkConstList;

        map<sql:ReferentialConstraint[]> refConstMap = {};

        stream<record {}, sql:Error?> refResults = self.dbClient->query(
            `SELECT UCC.CONSTRAINT_NAME, UCC.TABLE_NAME, UCC.COLUMN_NAME, UC.DELETE_RULE, UC.UPDATE_RULE
            FROM USER_CONSTRAINTS UC
            JOIN USER_CONS_COLUMNS UCC
            ON UC.CONSTRAINT_NAME = UCC.CONSTRAINT_NAME
            AND UC.OWNER = UCC.OWNER
            WHERE UCC.TABLE_NAME = ${tableName};`
        );
        do {
            check from record {} result in refResults
                do {
                    sql:ReferentialConstraint ref = {
                        name: <string>result["CONSTRAINT_NAME"],
                        tableName: <string>result["TABLE_NAME"],
                        columnName: <string>result["COLUMN_NAME"],
                        updateRule: <sql:ReferentialRule>result["UPDATE_RULE"],
                        deleteRule: <sql:ReferentialRule>result["DELETE_RULE"]
                    };

                    string colName = <string>result["COLUMN_NAME"];
                    if refConstMap[colName] is () {
                        refConstMap[colName] = [];
                    }
                    refConstMap.get(colName).push(ref);
                };
        } on fail error e {
            return error sql:Error(string `Error while reading referential constraints in the ${tableName} table, in the ${self.database} database.`, cause = e);
        }

        foreach sql:ColumnDefinition col in <sql:ColumnDefinition[]>tableDef.columns {
            sql:ReferentialConstraint[]? refConst = refConstMap[col.name];
            if refConst is sql:ReferentialConstraint[] && refConst.length() != 0 {
                col.referentialConstraints = refConst;
            }
        }

        check refResults.close();

        return tableDef;
    }

    # Retrieves parameter information of the provided routine in the database.
    #
    # + name - The name of the routine
    # + return - An 'sql:ParameterDefinition[]' or an `sql:Error`
    isolated function getParameters(string name) returns sql:ParameterDefinition[]|sql:Error {
        sql:ParameterDefinition[] parameterList = [];

        stream<sql:ParameterDefinition, sql:Error?> paramResults = self.dbClient->query(
            `SELECT UA.IN_OUT as PARAMETER_MODE, UA.ARGUMENT_NAME as PARAMETER_NAME, UA.DATA_TYPE
            FROM USER_ARGUMENTS UA
            JOIN USER_PROCEDURES UP
            ON UA.OBJECT_NAME = UP.OBJECT_NAME
            WHERE UP.OBJECT_NAME = ${name};`
        );
        do {
            check from sql:ParameterDefinition parameters in paramResults
                do {
                    sql:ParameterDefinition 'parameter = {
                        mode: <sql:ParameterMode>parameters["PARAMETER_MODE"],
                        name: <string>parameters["PARAMETER_NAME"],
                        'type: <string>parameters["DATA_TYPE"]
                    };
                    parameterList.push('parameter);
                };
        } on fail error e {
            return error sql:Error(string `Error while reading parameters in the ${name} routine, in the ${self.database} database.`, cause = e);
        }

        check paramResults.close();

        return parameterList;
    }

    public isolated function close() returns error? {
        do {
            _ = check self.dbClient.close();
        } on fail error e {
            return error("Error while closing the client", cause = e);
        }
    }
}
