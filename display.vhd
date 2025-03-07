-- Código FPGA - Comunicação com Display LCD e Nios Processor
-- Autor: Thiago de Oliveira Rodrigues

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;


ENTITY Display IS
	GENERIC (
		clock_vel : INTEGER := 100;		-- em MHz
		spi_vel   : INTEGER := 10			-- em MHz
	);
	
	PORT (
		i_clk, i_miso : IN STD_LOGIC;					-- miso é declarado, mas não é implementado aqui
		chaves: IN STD_LOGIC_VECTOR(4 DOWNTO 0);	-- Usado apenas para receber o reset
		imagem_enable: IN STD_LOGIC_VECTOR(2 DOWNTO 0);
		sdcard_data_read: IN STD_LOGIC_VECTOR(15 DOWNTO 0);
		busy, o_cs, o_reset, o_dc, o_mosi, o_sck, o_lcd_LED: OUT std_logic
	);
END ENTITY;

ARCHITECTURE main OF Display IS
-- Definicação dos comandos de inicialização e funções do Display LCD
	TYPE t_commands IS ARRAY (NATURAL RANGE <>) OF std_logic_vector(8 DOWNTO 0);
	CONSTANT sequencia_inicializacao : t_commands (12 DOWNTO 0) := (
	 "000000001", -- software reset
    "000010011", -- normal mode on
    "000100000", -- inversion off
    "001010001", -- brightness
    "111111111", -- max brightness
    "000100110", -- gama
    "100000001", -- curva de gama 1
    "000111010", -- formato de pixel
    "101010101", -- formato 16 bits
	 "000110110", -- Memory Access Control
	 "101000000", -- Definir Row "top to bottom" em Memory write(B7), Column L/R (B6)  e Display refresh(B4)
	 "000010001", -- sleep out
    "000101001"); -- display on
	 
-- Definição mudança de modo retrato e paisagem
	CONSTANT sequencia_retrato : t_commands (11 DOWNTO 0) := (
		"000110110",	-- Memory Access Control	
		"101000000",	-- B5 - Troca Row/Column
		"000101010",	-- altera coluna addr
		"100000000",	
		"100000000",	-- start column 0
		"100000000",
		"111101111",		-- end column 239
		"000101011",	-- altera linha addr
		"100000000",	
		"100000000",	-- start linha 0
		"100000001",
		"100111111"		-- end linha 319
	);
	CONSTANT sequencia_paisagem : t_commands (11 DOWNTO 0) := (
		"000110110",	-- Memory Access Control		
		"111100000",		-- B5 - Troca Row/Column
		"000101010",	-- altera coluna addr
		"100000000",	
		"100000000",	-- start column 0
		"100000001",
		"100111111",		-- end column 319
		"000101011",	-- altera linha addr
		"100000000",	
		"100000000",	-- start linha 0
		"100000000",
		"111101111"		-- end linha 239
	);
	
-- Constantes de Comando para o Display LCD
	CONSTANT constante_comando_escrever : std_logic_vector (7 DOWNTO 0) := "00101100";
	CONSTANT constante_comando_nop 		: std_logic_vector (7 DOWNTO 0) := "00000000";

	
-- Status de envio SPI 
	TYPE status IS (parado, modo_inicializacao, wait_5msec, wait_150msec, comando_escrever, pixels, wait_data, comando_orientacao, comando_nop, modo_idle);
	SIGNAL spi_status : status := parado;
	
-- Variáveis de posicionamento e dados no Display	 
	SIGNAL RGB : std_logic_vector(0 TO 15):= (OTHERS => '0');
	SIGNAL pixel : INTEGER RANGE RGB'low TO RGB'high := 0;	
	
-- Outras variáveis
	SIGNAL reset, sck_enable, clk_spi, ativador_pixel: std_logic := '0';	
	SIGNAL ren_lcd, read_nios, busy_aux: std_logic := '0';		

BEGIN
	o_sck <= clk_spi WHEN sck_enable = '1' ELSE '0';	-- Habilita o clock spi para o display
	busy  <= busy_aux;
	reset <= chaves(4);
	
	spi_clock: PROCESS (i_clk)
		CONSTANT ciclos: INTEGER:= (clock_vel/(2*spi_vel));
		VARIABLE conta_tempo: INTEGER RANGE 0 TO ciclos+1 :=0;
	BEGIN
		IF rising_edge(i_clk) THEN
			IF conta_tempo>=ciclos THEN
				conta_tempo:=0;
				clk_spi<= not clk_spi;
			ELSE
				conta_tempo:=conta_tempo+1;
			END IF;
		END IF;
	END PROCESS;
	
	
	-- Ativador para leitura da imagem
	sdcard_imagem: PROCESS (imagem_enable(1))
	BEGIN
		IF rising_edge(imagem_enable(1)) AND reset='1' THEN
			ren_lcd <= not ren_lcd;
		END IF;
	END PROCESS;
	
	-- Ativador para leitura do pixel
	sdcard_pixel: PROCESS (i_clk)
		VARIABLE ativador: STD_LOGIC:='0';
	BEGIN
		IF rising_edge(i_clk) THEN
			IF reset='0' THEN
				read_nios <= '0';
				ativador := '0';
			ELSIF(imagem_enable(0)='1' AND ativador='0') THEN
				read_nios <= '1';
				ativador := '1';
			ELSIF (ativador_pixel='1') THEN
				read_nios <= '0';
			ELSIF (imagem_enable(0)='0') THEN
				ativador := '0';
			END IF;
		END IF;
	END PROCESS;

	-- process SPI para enviar os dados para o display lcd
	spi_display : PROCESS (clk_spi, reset)
		VARIABLE contador_inicio: INTEGER RANGE 0 TO (spi_vel*200000) := 0;
		VARIABLE contagem_bits : INTEGER RANGE 7 DOWNTO 0 := 7;
		VARIABLE contagem_comandos : INTEGER RANGE 0 TO (sequencia_inicializacao'HIGH) := sequencia_inicializacao'HIGH;
		VARIABLE comando_enviar : std_logic_vector (8 DOWNTO 0):=sequencia_inicializacao(sequencia_inicializacao'HIGH);
		VARIABLE orientacao_comandos : INTEGER RANGE 0 TO (sequencia_paisagem'HIGH) := sequencia_paisagem'HIGH;
		VARIABLE orientacao_enviar : std_logic_vector (8 DOWNTO 0);
		VARIABLE reload_save: std_logic:=ren_lcd;
	BEGIN
		IF falling_edge(clk_spi) THEN
			IF reset = '0' THEN
			-- Reseta variáveis, sinais e reinializa o display
				sck_enable <= '0';
				o_dc <= '0';
				o_cs <= '1';
				o_mosi <= '0';
				o_reset<='1';			
				contador_inicio := 0;
				contagem_bits := 7;			
				contagem_comandos := sequencia_inicializacao'HIGH;
				orientacao_comandos := sequencia_paisagem'HIGH;
				comando_enviar :=sequencia_inicializacao(sequencia_inicializacao'HIGH);			
				reload_save:=ren_lcd;
				pixel <= 0;
				Ativador_pixel<='0';
				busy_aux <='0';				
				o_lcd_LED <= '0';			
				spi_status <= modo_inicializacao;
			
			ELSE
				CASE spi_status IS
					WHEN parado => 
						o_lcd_LED <= '0';
						o_mosi <= '0';				
						o_dc <= '0';
						o_cs <= '1';
						
						-- Espera 5msec antes de iniciar o display
						IF contador_inicio >= (spi_vel*5000) THEN
							spi_status <= modo_inicializacao;
							contador_inicio:=0;
						ELSE
							contador_inicio := contador_inicio +1;
						END IF;

					WHEN modo_inicializacao =>
						busy_aux <='1';
						o_cs <= '0';
						sck_enable <= '1';
						o_mosi <= comando_enviar(contagem_bits);
						o_dc <= comando_enviar(8);

						IF contagem_bits > 0 THEN
							contagem_bits := contagem_bits - 1;
						ELSE
							contagem_bits := 7;
							IF contagem_comandos > 0 then
								-- Gerenciar Delays para Sleep_out, Display_on e Software_reset
								IF comando_enviar = "000010001" then  -- Sleep_out
									 spi_status <= wait_150msec;    -- Delay de 150 ms
								ELSIF comando_enviar = "000101001" then  -- Display_on
									 spi_status <= wait_150msec;    -- Delay de 150 ms
								ELSIF comando_enviar = "000000001" then	-- Software_reset
									spi_status <= wait_5msec;		  -- Delay de 5 ms
								END IF;
								contagem_comandos := contagem_comandos - 1;
								comando_enviar := sequencia_inicializacao(contagem_comandos);
							ELSE
								contagem_comandos := sequencia_inicializacao'HIGH;
								comando_enviar :=sequencia_inicializacao(sequencia_inicializacao'HIGH);
								o_lcd_LED <= '1';	
								spi_status <= modo_idle;
							END IF;
						END IF;
						
					WHEN wait_5msec =>
						o_dc <= '0';
						o_cs <= '1';
						sck_enable <= '0';
						o_mosi <= '0';
						-- Espera 5msec antes prosseguir
						IF contador_inicio >= (spi_vel*5000) THEN
							spi_status <= modo_inicializacao;
							contador_inicio:=0;
						ELSE
							contador_inicio := contador_inicio +1;
						END IF;
						
					WHEN wait_150msec =>
						o_dc <= '0';
						o_cs <= '1';
						sck_enable <= '0';
						o_mosi <= '0';
						-- Espera 5msec antes prosseguir
						IF contador_inicio >= (spi_vel*150000) THEN
							spi_status <= modo_inicializacao;
							contador_inicio:=0;
						ELSE
							contador_inicio := contador_inicio +1;
						END IF;	
						
					WHEN comando_escrever =>
						busy_aux <='1';
						o_lcd_LED <= '1';
						o_dc <= '0';
						o_cs <= '0';
						sck_enable <= '1';
						o_mosi <= constante_comando_escrever(contagem_bits);
								
						IF contagem_bits > 0 THEN
							contagem_bits := contagem_bits - 1;
						ELSE
							contagem_bits := 7;
							IF read_nios='1' THEN
								spi_status <= pixels;
								RGB(0 to 15) <= sdcard_data_read(15 DOWNTO 0);
								ativador_pixel<='1';
							ELSE
								spi_status <= wait_data;
							END IF;
						END IF;
						
					WHEN pixels => 
						busy_aux <='1';
						ativador_pixel<='0';
						sck_enable <= '1';
						o_dc <= '1';
						o_cs <= '0';

						o_mosi <= RGB(pixel);

						IF pixel = (pixel'HIGH) THEN
							pixel <= 0;
							busy_aux <='0';
							IF imagem_enable(1)='0' THEN
								-- finalizou imagem
								spi_status <= comando_nop;
							ELSIF read_nios='1' THEN
								-- continua em pixels
								RGB(0 to 15) <= sdcard_data_read(15 DOWNTO 0);
							ELSE
								-- fica esperando novo pixel
								spi_status <= wait_data;
							END IF;
						ELSE
							pixel <= pixel + 1;
						END IF;
						
					WHEN wait_data =>
						busy_aux <='0';
						o_dc <= '1';
						o_cs <= '1';
						sck_enable <= '1';
						o_mosi <= '0';
						IF imagem_enable(1)='0' THEN
							spi_status <= comando_nop;
						ELSIF (read_nios='1') THEN
							spi_status <= pixels;
							RGB(0 to 15) <= sdcard_data_read(15 DOWNTO 0);
							ativador_pixel<='1';
						END IF;
					WHEN comando_orientacao =>
						o_cs <= '0';
						sck_enable <= '1';
						o_mosi <= orientacao_enviar(contagem_bits);
						o_dc <= orientacao_enviar(8);

						IF contagem_bits > 0 THEN
							contagem_bits := contagem_bits - 1;
						ELSE
							contagem_bits := 7;
							IF orientacao_comandos > 0 then
								orientacao_comandos := orientacao_comandos - 1;
								IF imagem_enable(2)='0' THEN	
									orientacao_enviar:=sequencia_retrato(orientacao_comandos);
								ELSE									
									orientacao_enviar:=sequencia_paisagem(orientacao_comandos);
								END IF;
							ELSE								
								spi_status <= comando_escrever;
								orientacao_comandos := sequencia_paisagem'HIGH;
							END IF;						
						END IF;
						
					WHEN comando_nop =>
						busy_aux <='1';
						o_dc <= '0';
						o_cs <= '0';
						sck_enable <= '1';
						o_mosi <= constante_comando_nop(contagem_bits);

						IF contagem_bits > 0 THEN
							contagem_bits := contagem_bits - 1;
						ELSE
							contagem_bits := 7;
							spi_status <= modo_idle;
						END IF;
						
					WHEN modo_idle =>
						busy_aux <='0';
						o_dc <= '0';
						o_cs <= '1';
						sck_enable <= '0';
						o_mosi <= '0';						
							
						IF (ren_lcd /= reload_save) THEN	-- Atualiza a imagem
							reload_save:=ren_lcd;
							busy_aux <='1';
							spi_status<=comando_orientacao;
							IF imagem_enable(2)='0' THEN	-- modo retrato 240x320
								--spi_status <= modo_retrato;
								orientacao_enviar:=sequencia_retrato(sequencia_retrato'HIGH);
							ELSE									-- modo retrato 320x240
								--spi_status <= modo_paisagem;
								orientacao_enviar:=sequencia_paisagem(sequencia_paisagem'HIGH);
							END IF;
							
						END IF;
						 
				END CASE;
			END IF;
		END IF;
	END PROCESS;	
	

END main;